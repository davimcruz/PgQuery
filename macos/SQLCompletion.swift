import Foundation

// MARK: - Schema catalog

struct SchemaColumn: Equatable {
    var name: String
    var type: String
}

struct SchemaRelation: Equatable {
    enum Kind: String { case table = "r", view = "v", materializedView = "m", foreignTable = "f", partitionedTable = "p" }
    var schema: String
    var name: String
    var kind: Kind
    var columns: [SchemaColumn]

    var kindLabel: String {
        switch kind {
        case .table, .partitionedTable: return "tabela"
        case .view: return "view"
        case .materializedView: return "view materializada"
        case .foreignTable: return "tabela externa"
        }
    }
}

final class SchemaCatalog {
    let relations: [SchemaRelation]
    let schemas: [String]
    private var byName: [String: [Int]] = [:]
    private var byLowerName: [String: [Int]] = [:]

    init(relations: [SchemaRelation]) {
        self.relations = relations
        var seen = Set<String>()
        schemas = relations.map(\.schema).filter { seen.insert($0).inserted }.sorted()
        for (index, relation) in relations.enumerated() {
            byName[relation.name, default: []].append(index)
            byLowerName[relation.name.lowercased(), default: []].append(index)
        }
    }

    /// Builds the catalog from rows of `[schema, relation, column, type, relkind]`.
    convenience init(rows: [[String]]) {
        var relations: [SchemaRelation] = []
        var index: [String: Int] = [:]
        for row in rows where row.count >= 4 {
            let key = row[0] + "\u{0}" + row[1]
            if index[key] == nil {
                index[key] = relations.count
                let kind = row.count > 4 ? SchemaRelation.Kind(rawValue: row[4]) ?? .table : .table
                relations.append(SchemaRelation(schema: row[0], name: row[1], kind: kind, columns: []))
            }
            relations[index[key]!].columns.append(SchemaColumn(name: row[2], type: row[3]))
        }
        self.init(relations: relations)
    }

    static let empty = SchemaCatalog(relations: [])

    /// Resolves a (possibly schema-qualified) relation reference the way
    /// PostgreSQL would with the default search path, falling back to a
    /// case-insensitive match so sloppy casing still completes.
    func relation(schema: String?, name: String) -> SchemaRelation? {
        let exact = (byName[name] ?? []).map { relations[$0] }
        let candidates = exact.isEmpty ? (byLowerName[name.lowercased()] ?? []).map { relations[$0] } : exact
        if let schema {
            return candidates.first { $0.schema == schema } ?? candidates.first { $0.schema.lowercased() == schema.lowercased() }
        }
        return candidates.first { $0.schema == "public" } ?? candidates.first
    }

    func hasSchema(_ name: String) -> String? {
        schemas.first { $0 == name } ?? schemas.first { $0.lowercased() == name.lowercased() }
    }
}

// MARK: - Completion model

enum CompletionKind: Int {
    case column, alias, table, view, schema, function, keyword

    var badge: String {
        switch self {
        case .column: return "C"
        case .alias: return "A"
        case .table: return "T"
        case .view: return "V"
        case .schema: return "S"
        case .function: return "ƒ"
        case .keyword: return "K"
        }
    }
}

struct CompletionItem: Equatable {
    var kind: CompletionKind
    var label: String
    var detail: String
    var insertText: String
    /// Characters to move the caret back from the end of the insertion
    /// (e.g. 1 to land inside the parentheses of `count()`).
    var caretBackOffset = 0
    /// Re-open the list after inserting (used after inserting `schema.`).
    var retrigger = false
    var score = 0
}

enum SQLClause: Equatable {
    case statementStart
    case relation          // FROM / JOIN / UPDATE / INTO … expecting a table
    case afterRelation     // right after a table reference (alias or keyword next)
    case column            // select list, WHERE, ON, SET, ORDER BY …
    case afterExpression   // e.g. `WHERE id |` – an operator/keyword comes next
    case noSuggestions     // alias names, LIMIT values …
    case unknown
}

struct TableReference: Equatable {
    var schema: String?
    var name: String?
    var alias: String?
    /// Output columns for CTEs and derived tables (`FROM (SELECT …) x`).
    var derivedColumns: [String]?

    var visibleName: String? { alias ?? name }
}

struct CompletionContext {
    var replacementRange: NSRange
    var prefix: String
    var quoted: Bool
    var qualifier: [String]
    var clause: SQLClause
    var scope: [TableReference]
    var ctes: [TableReference]
    /// Whether the prefix was typed in lower case (keywords then follow it).
    var prefersLowercase: Bool
}

// MARK: - Engine

struct SQLCompletionEngine {
    var catalog: SchemaCatalog

    // MARK: Context analysis

    func context(in source: NSString, caret: Int, tokens allTokens: [SQLToken]? = nil) -> CompletionContext? {
        let caret = max(0, min(caret, source.length))
        let tokens = allTokens ?? SQLLexer.tokenize(source)
        var quoted = false
        var replacement = NSRange(location: caret, length: 0)
        var prefix = ""
        var prefixStart = caret

        if let token = SQLLexer.token(at: caret, in: tokens), caret > token.range.location {
            let insideOpen = caret < token.end || !token.isTerminated
            switch token.kind {
            case .string, .parameter:
                if insideOpen || token.kind == .parameter { return nil }
            case .comment:
                if insideOpen || token.text.hasPrefix("--") { return nil }
            case .quotedIdentifier where insideOpen:
                quoted = true
                prefixStart = token.range.location
                let innerStart = token.range.location + 1
                let innerEnd = token.isTerminated ? token.end - 1 : token.end
                replacement = NSRange(location: innerStart, length: (token.isTerminated ? token.end : innerEnd) - innerStart)
                prefix = source.substring(with: NSRange(location: innerStart, length: max(0, caret - innerStart)))
                    .replacingOccurrences(of: "\"\"", with: "\"")
            case .word:
                prefixStart = token.range.location
                replacement = token.range
                prefix = source.substring(with: NSRange(location: token.range.location, length: caret - token.range.location))
            case .number:
                return nil
            default:
                break
            }
        }

        // Qualifier chain right before the prefix: `schema.table.` / `alias.`
        let before = tokens.filter { $0.end <= prefixStart }
        var qualifier: [String] = []
        var cursor = before.count - 1
        while cursor >= 1, before[cursor].kind == .symbol, before[cursor].text == ".",
              before[cursor].end == (qualifier.isEmpty ? prefixStart : before[cursor + 1].range.location),
              let name = before[cursor - 1].identifierValue, before[cursor - 1].end == before[cursor].range.location {
            qualifier.insert(name, at: 0)
            cursor -= 2
            if qualifier.count == 2 { break }
        }
        let qualifierStart = cursor + 1 < before.count ? before[cursor + 1].range.location : prefixStart

        // Restrict analysis to the statement under the caret.
        let statements = SQLLexer.statementRanges(in: source, tokens: tokens)
        let statement = statements.first { caret >= $0.location && caret <= $0.location + $0.length } ?? NSRange(location: 0, length: source.length)
        let statementTokens = tokens.filter {
            !$0.isTrivia && $0.range.location >= statement.location && $0.end <= statement.location + statement.length
        }
        let preceding = statementTokens.filter { $0.end <= qualifierStart }
        let clause = qualifier.isEmpty ? Self.clause(for: preceding) : .column
        let (scope, ctes) = Self.tableReferences(in: statementTokens.filter { $0.range.location != prefixStart || quoted })

        let letters = prefix.filter(\.isLetter)
        return CompletionContext(
            replacementRange: replacement,
            prefix: prefix,
            quoted: quoted,
            qualifier: qualifier,
            clause: clause,
            scope: scope,
            ctes: ctes,
            prefersLowercase: !letters.isEmpty && letters == letters.lowercased()
        )
    }

    private static let relationKeywords: Set<String> = ["FROM", "JOIN", "UPDATE", "INTO", "TABLE", "TRUNCATE", "REFERENCES"]
    private static let columnKeywords: Set<String> = [
        "SELECT", "WHERE", "ON", "AND", "OR", "NOT", "BY", "HAVING", "SET", "RETURNING", "WHEN", "THEN", "ELSE",
        "CASE", "DISTINCT", "USING", "VALUES", "BETWEEN", "LIKE", "ILIKE", "IN", "IS", "ALL", "ANY", "SOME", "OVER",
        "FILTER", "PARTITION",
    ]
    private static let noSuggestionKeywords: Set<String> = ["AS", "LIMIT", "OFFSET", "FETCH"]
    /// DDL nouns followed by a new object name (`CREATE INDEX |`).
    private static let objectNameKeywords: Set<String> = ["INDEX", "VIEW", "SCHEMA", "DATABASE", "FUNCTION", "TRIGGER", "SEQUENCE", "EXTENSION", "ROLE", "TYPE", "DOMAIN", "POLICY"]
    private static let joinModifiers: Set<String> = ["LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "NATURAL", "LATERAL", "ONLY"]

    static func clause(for tokens: [SQLToken]) -> SQLClause {
        guard let last = tokens.last else { return .statementStart }
        let beforeLast = tokens.dropLast().last
        let lastIsStar = last.kind == .symbol && last.text == "*"
            && (beforeLast == nil || beforeLast!.upper == "SELECT" || beforeLast!.text == "," || beforeLast!.text == ".")
        let lastIsValue = [.word, .quotedIdentifier, .number, .string, .parameter].contains(last.kind) && !(last.kind == .word && SQLVocabulary.keywords.contains(last.upper))
            || (last.kind == .symbol && last.text == ")") || lastIsStar
            || (last.kind == .word && ["NULL", "TRUE", "FALSE", "CURRENT_DATE", "CURRENT_TIMESTAMP", "CURRENT_USER"].contains(last.upper))
        if last.kind == .symbol && last.text == "(" {
            // `FROM (`, `IN (`, `EXISTS (` usually start a sub-query.
            let previous = tokens.dropLast().last
            if previous == nil { return .statementStart }
            if let previous, previous.kind == .word, ["FROM", "JOIN", "EXISTS", "AS", "LATERAL"].contains(previous.upper) { return .statementStart }
        }
        if last.kind == .word, last.upper == "AS" || objectNameKeywords.contains(last.upper) { return .noSuggestions }

        var depth = 0
        for token in tokens.reversed() {
            if token.kind == .symbol {
                if token.text == ")" { depth += 1; continue }
                if token.text == "(" {
                    if depth == 0 { return lastIsValue ? .afterExpression : .column }
                    depth -= 1
                    continue
                }
                continue
            }
            guard depth == 0, token.kind == .word else { continue }
            let word = token.upper
            if relationKeywords.contains(word) {
                if token == last { return .relation }
                if word == "FROM" || word == "JOIN", last.kind == .symbol, last.text == "," { return .relation }
                if joinModifiers.contains(last.upper) && last.kind == .word { return .afterRelation }
                return lastIsValue ? .afterRelation : .relation
            }
            if columnKeywords.contains(word) {
                return lastIsValue ? .afterExpression : .column
            }
            if noSuggestionKeywords.contains(word) {
                return token == last ? .noSuggestions : (lastIsValue ? .afterExpression : .unknown)
            }
            if word == "NULL" || word == "TRUE" || word == "FALSE" { continue }
            if ["INSERT", "DELETE", "CREATE", "ALTER", "DROP"].contains(word), token == last { return .unknown }
            if ["WITH", "EXPLAIN", "ANALYZE", "BEGIN", "UNION", "INTERSECT", "EXCEPT"].contains(word), token == last { return .statementStart }
        }
        return .unknown
    }

    /// Finds the relations a statement reads from (FROM / JOIN / UPDATE /
    /// INTO), with their aliases, plus CTE definitions.
    static func tableReferences(in tokens: [SQLToken]) -> (scope: [TableReference], ctes: [TableReference]) {
        var scope: [TableReference] = []
        var ctes: [TableReference] = []
        let stop: Set<String> = SQLVocabulary.reserved.union(["SET", "VALUES", "DEFAULT", "LIMIT", "OFFSET", "RETURNING", "WINDOW"])

        func matchingParen(from open: Int) -> Int {
            var depth = 0
            var index = open
            while index < tokens.count {
                if tokens[index].kind == .symbol {
                    if tokens[index].text == "(" { depth += 1 }
                    else if tokens[index].text == ")" { depth -= 1; if depth == 0 { return index } }
                }
                index += 1
            }
            return tokens.count  // unbalanced: the group runs to the end
        }

        func isSymbol(_ index: Int, _ text: String) -> Bool {
            index < tokens.count && tokens[index].kind == .symbol && tokens[index].text == text
        }

        // CTEs: WITH [RECURSIVE] name [(cols)] AS [NOT] [MATERIALIZED] ( … ) [, …]
        if let first = tokens.first, first.upper == "WITH" {
            var index = 1
            if index < tokens.count, tokens[index].upper == "RECURSIVE" { index += 1 }
            while index < tokens.count, let name = tokens[index].identifierValue {
                index += 1
                var columns: [String]?
                if isSymbol(index, "(") {
                    let close = matchingParen(from: index)
                    columns = tokens[(index + 1)..<close].compactMap(\.identifierValue)
                    index = close + 1
                }
                guard index < tokens.count, tokens[index].upper == "AS" else { break }
                index += 1
                while index < tokens.count, ["NOT", "MATERIALIZED"].contains(tokens[index].upper) { index += 1 }
                guard isSymbol(index, "(") else { break }
                let close = matchingParen(from: index)
                let body = Array(tokens[(index + 1)..<close])
                ctes.append(TableReference(schema: nil, name: name, alias: nil, derivedColumns: columns ?? selectListNames(body)))
                index = close + 1
                guard isSymbol(index, ",") else { break }
                index += 1
            }
        }

        var index = 0
        while index < tokens.count {
            let word = tokens[index].kind == .word ? tokens[index].upper : ""
            guard ["FROM", "JOIN", "UPDATE", "INTO"].contains(word) else { index += 1; continue }
            // `DELETE FROM`, `INSERT INTO`, `UPDATE x` all name exactly one
            // relation; FROM allows a comma-separated list.
            var cursor = index + 1
            while true {
                while cursor < tokens.count, ["ONLY", "LATERAL"].contains(tokens[cursor].upper) { cursor += 1 }
                guard cursor < tokens.count else { break }
                var reference = TableReference()
                if isSymbol(cursor, "(") {
                    let close = matchingParen(from: cursor)
                    reference.derivedColumns = selectListNames(Array(tokens[(cursor + 1)..<close]))
                    cursor = close + 1
                } else if let first = tokens[cursor].identifierValue,
                          !(tokens[cursor].kind == .word && stop.contains(tokens[cursor].upper)) {
                    var parts = [first]
                    cursor += 1
                    while isSymbol(cursor, "."), cursor + 1 < tokens.count, let part = tokens[cursor + 1].identifierValue {
                        parts.append(part)
                        cursor += 2
                    }
                    reference.name = parts.last
                    reference.schema = parts.count >= 2 ? parts[parts.count - 2] : nil
                    if isSymbol(cursor, "(") && word == "INTO" { cursor = matchingParen(from: cursor) + 1 }
                } else {
                    break
                }
                if cursor < tokens.count, tokens[cursor].upper == "AS" { cursor += 1 }
                if cursor < tokens.count, let alias = tokens[cursor].identifierValue,
                   !(tokens[cursor].kind == .word && stop.contains(tokens[cursor].upper)) {
                    reference.alias = alias
                    cursor += 1
                }
                if reference.name != nil || reference.alias != nil { scope.append(reference) }
                guard word == "FROM", isSymbol(cursor, ",") else { break }
                cursor += 1
            }
            index = max(cursor, index + 1)
        }
        // A CTE referenced by name exposes the CTE's columns.
        for (position, reference) in scope.enumerated() where reference.schema == nil && reference.derivedColumns == nil {
            if let cte = ctes.first(where: { $0.name == reference.name }) {
                scope[position].derivedColumns = cte.derivedColumns
            }
        }
        return (scope, ctes)
    }

    /// Output column names of a SELECT body (aliases or trailing identifiers).
    static func selectListNames(_ tokens: [SQLToken]) -> [String] {
        guard let start = tokens.firstIndex(where: { $0.upper == "SELECT" }) else { return [] }
        var names: [String] = []
        var item: [SQLToken] = []
        var depth = 0
        func flush() {
            defer { item.removeAll() }
            guard let last = item.last, let name = last.identifierValue else { return }
            if last.kind == .word && SQLVocabulary.reserved.contains(last.upper) { return }
            names.append(name)
        }
        for token in tokens[(start + 1)...] {
            if token.kind == .symbol {
                if token.text == "(" { depth += 1 } else if token.text == ")" { depth -= 1 }
                if depth == 0 && token.text == "," { flush(); continue }
            }
            if depth == 0 && token.kind == .word && ["FROM", "WHERE", "GROUP", "ORDER", "LIMIT", "UNION"].contains(token.upper) { break }
            if depth == 0 && token.kind == .word && token.upper == "DISTINCT" && item.isEmpty { continue }
            item.append(token)
        }
        flush()
        return names
    }

    // MARK: Candidates

    func items(for context: CompletionContext) -> [CompletionItem] {
        var items: [CompletionItem] = []
        let caseFor = { (keyword: String) in context.prefersLowercase ? keyword.lowercased() : keyword }

        func addColumns(of reference: TableReference, qualify: String?, boost: Int) {
            let owner = reference.visibleName ?? ""
            if let derived = reference.derivedColumns {
                for name in derived {
                    items.append(column(name, type: "", owner: owner, qualify: qualify, context: context, boost: boost))
                }
            } else if let name = reference.name, let relation = catalog.relation(schema: reference.schema, name: name) {
                for col in relation.columns {
                    items.append(column(col.name, type: col.type, owner: owner, qualify: qualify, context: context, boost: boost))
                }
            }
        }

        if !context.qualifier.isEmpty {
            let qualifier = context.qualifier
            if qualifier.count == 1 {
                let name = qualifier[0]
                // Only references that resolve to known columns count; the
                // half-typed `FROM billing.` itself must not shadow the schema.
                let resolvable = context.scope.filter(resolves)
                let byAlias = resolvable.first { $0.alias == name }
                let byName = resolvable.first { $0.alias == nil && $0.name == name }
                let loose = resolvable.first { $0.visibleName?.lowercased() == name.lowercased() }
                if let reference = byAlias ?? byName ?? loose {
                    addColumns(of: reference, qualify: nil, boost: 0)
                } else if let cte = context.ctes.first(where: { $0.name == name }) {
                    addColumns(of: cte, qualify: nil, boost: 0)
                } else if let schema = catalog.hasSchema(name) {
                    for relation in catalog.relations where relation.schema == schema {
                        items.append(relationItem(relation, qualifySchema: false, context: context))
                    }
                } else if let relation = catalog.relation(schema: nil, name: name) {
                    addColumns(of: TableReference(schema: relation.schema, name: relation.name), qualify: nil, boost: 0)
                }
            } else if let relation = catalog.relation(schema: qualifier[0], name: qualifier[1]) {
                addColumns(of: TableReference(schema: relation.schema, name: relation.name), qualify: nil, boost: 0)
            }
            return rank(items, prefix: context.prefix)
        }

        switch context.clause {
        case .noSuggestions:
            return []
        case .statementStart:
            if !context.quoted {
                items += SQLVocabulary.statementStarters.map { keyword($0, caseFor) }
            }
        case .relation:
            for cte in context.ctes {
                items.append(CompletionItem(kind: .table, label: cte.name ?? "", detail: "CTE", insertText: identifier(cte.name ?? "", context: context), score: 30))
            }
            for relation in catalog.relations {
                items.append(relationItem(relation, qualifySchema: relation.schema != "public", context: context))
            }
            for schema in catalog.schemas where schema != "public" {
                var item = CompletionItem(kind: .schema, label: schema, detail: "schema", insertText: identifier(schema, context: context) + ".", score: -10)
                item.retrigger = true
                items.append(item)
            }
            if !context.quoted && !context.prefix.isEmpty {
                items += ["LATERAL", "ONLY"].map { keyword($0, caseFor) }
            }
        case .afterRelation:
            if !context.quoted {
                items += SQLVocabulary.afterRelation.map { keyword($0, caseFor) }
            }
        case .column, .afterExpression, .unknown:
            let ambiguous = ambiguousColumns(in: context.scope)
            for reference in context.scope {
                let start = items.count
                addColumns(of: reference, qualify: nil, boost: 20)
                // When several tables share a column name, insert it
                // qualified (`o.id`) so the query is not ambiguous.
                if context.scope.count > 1, !context.quoted, let visible = reference.visibleName {
                    for index in start..<items.count where ambiguous.contains(items[index].label) {
                        items[index].insertText = Self.quoteIfNeeded(visible) + "." + items[index].insertText
                    }
                }
            }
            if context.scope.isEmpty {
                // No FROM yet (e.g. `SELECT na|`): offer every known column once.
                var seen: [String: Int] = [:]
                for relation in catalog.relations {
                    for col in relation.columns {
                        // Filter before building items: a large catalog has
                        // tens of thousands of columns.
                        guard Self.matchScore(col.name, prefix: context.prefix) != nil else { continue }
                        if let existing = seen[col.name] {
                            items[existing].detail = col.type + " · várias tabelas"
                        } else {
                            seen[col.name] = items.count
                            items.append(column(col.name, type: col.type, owner: relation.name, qualify: nil, context: context, boost: 0))
                        }
                    }
                }
            }
            for reference in context.scope {
                if let visible = reference.visibleName {
                    items.append(CompletionItem(kind: .alias, label: visible, detail: reference.alias != nil ? "alias de \(reference.name ?? "subconsulta")" : "tabela na consulta", insertText: identifier(visible, context: context), score: 10))
                }
            }
            if !context.quoted {
                items += SQLVocabulary.functions.map {
                    CompletionItem(kind: .function, label: $0.name, detail: $0.signature, insertText: (context.prefersLowercase || context.prefix.isEmpty ? $0.name : $0.name.uppercased()) + "()", caretBackOffset: 1, score: -5)
                }
                let keywords = context.clause == .afterExpression ? SQLVocabulary.afterExpression : context.clause == .unknown ? SQLVocabulary.allCompletionKeywords : SQLVocabulary.expressionKeywords
                items += keywords.map {
                    var item = keyword($0, caseFor)
                    item.score = context.clause == .afterExpression ? 40 : -15
                    return item
                }
            }
        }
        return rank(items, prefix: context.prefix)
    }

    private func resolves(_ reference: TableReference) -> Bool {
        if reference.derivedColumns != nil { return true }
        guard let name = reference.name else { return false }
        return catalog.relation(schema: reference.schema, name: name) != nil
    }

    private func ambiguousColumns(in scope: [TableReference]) -> Set<String> {
        var counts: [String: Int] = [:]
        for reference in scope {
            let names: [String]
            if let derived = reference.derivedColumns { names = derived }
            else if let name = reference.name, let relation = catalog.relation(schema: reference.schema, name: name) { names = relation.columns.map(\.name) }
            else { names = [] }
            for name in Set(names) { counts[name, default: 0] += 1 }
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    private func keyword(_ word: String, _ caseFor: (String) -> String) -> CompletionItem {
        CompletionItem(kind: .keyword, label: word, detail: "palavra-chave", insertText: caseFor(word) + " ", score: -20)
    }

    private func column(_ name: String, type: String, owner: String, qualify: String?, context: CompletionContext, boost: Int) -> CompletionItem {
        let detail = [type, owner].filter { !$0.isEmpty }.joined(separator: " · ")
        return CompletionItem(kind: .column, label: name, detail: detail, insertText: identifier(name, context: context), score: boost)
    }

    private func relationItem(_ relation: SchemaRelation, qualifySchema: Bool, context: CompletionContext) -> CompletionItem {
        let kind: CompletionKind = relation.kind == .view || relation.kind == .materializedView ? .view : .table
        let insert: String
        if context.quoted {
            insert = identifier(relation.name, context: context)
        } else {
            insert = (qualifySchema ? Self.quoteIfNeeded(relation.schema) + "." : "") + Self.quoteIfNeeded(relation.name)
        }
        return CompletionItem(kind: kind, label: relation.name, detail: "\(relation.kindLabel) · \(relation.schema)", insertText: insert, score: relation.schema == "public" ? 5 : 0)
    }

    /// Insertion text for an identifier: inside quotes it is inserted raw
    /// (with `"` escaped, closing quote added); otherwise it is quoted only
    /// when PostgreSQL requires it.
    private func identifier(_ name: String, context: CompletionContext) -> String {
        context.quoted ? name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : Self.quoteIfNeeded(name)
    }

    static func quoteIfNeeded(_ name: String) -> String {
        let simple = name.range(of: "^[a-z_][a-z0-9_$]*$", options: .regularExpression) != nil
        if simple && !SQLVocabulary.reserved.contains(name.uppercased()) { return name }
        return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Ranking

    /// Scores how well `name` matches `prefix`: exact prefix beats a match at
    /// a word boundary (`_`), which beats initials (`ci` → customer_id),
    /// which beats a plain substring.
    static func matchScore(_ name: String, prefix: String) -> Int? {
        guard !prefix.isEmpty else { return 0 }
        let lowerName = name.lowercased()
        let lowerPrefix = prefix.lowercased()
        if lowerName == lowerPrefix { return 1000 }
        if lowerName.hasPrefix(lowerPrefix) { return name.hasPrefix(prefix) ? 820 : 800 }
        let parts = lowerName.split(whereSeparator: { $0 == "_" || $0 == " " || $0 == "." }).map(String.init)
        if parts.dropFirst().contains(where: { $0.hasPrefix(lowerPrefix) }) { return 600 }
        if lowerPrefix.count >= 2 {
            let initials = String(parts.compactMap(\.first))
            if initials.hasPrefix(lowerPrefix) { return 500 }
        }
        if lowerPrefix.count >= 2, lowerName.contains(lowerPrefix) { return 300 }
        return nil
    }

    func rank(_ items: [CompletionItem], prefix: String) -> [CompletionItem] {
        var seen = Set<String>()
        let scored: [(offset: Int, item: CompletionItem)] = items.enumerated().compactMap { offset, item in
            guard let match = Self.matchScore(item.label, prefix: prefix) else { return nil }
            var item = item
            item.score += match
            return (offset, item)
        }
        return scored
            .sorted { $0.item.score != $1.item.score ? $0.item.score > $1.item.score : $0.offset < $1.offset }
            .map(\.item)
            .filter { seen.insert("\($0.kind.rawValue)|\($0.label)|\($0.insertText)").inserted }
            .prefix(300)
            .map { $0 }
    }

    // MARK: Auto-trigger policy

    enum Trigger { case dot, quote, identifierCharacter }

    /// Decides whether the list should open by itself. Typing a keyword like
    /// SELECT never opens it; the list appears when the user clearly asks
    /// for an identifier: after `.`, after an opening `"`, or while naming a
    /// relation after FROM / JOIN / UPDATE / INTO. `suggestWhileTyping`
    /// additionally opens it for column names (after two characters).
    static func shouldAutoOpen(_ context: CompletionContext, trigger: Trigger, suggestWhileTyping: Bool) -> Bool {
        switch trigger {
        case .dot:
            return !context.qualifier.isEmpty
        case .quote:
            return context.quoted
        case .identifierCharacter:
            if context.quoted || !context.qualifier.isEmpty { return true }
            if context.clause == .relation { return true }
            if suggestWhileTyping, context.prefix.count >= 2, context.clause == .column { return true }
            return false
        }
    }
}
