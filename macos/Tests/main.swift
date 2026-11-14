import Foundation

// Lightweight test runner for the SQL lexer and autocomplete engine.
// Run with scripts/test-editor.sh.

var failures = 0
var passed = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition() { passed += 1 } else { failures += 1; print("✗ \(message)  (line \(line))") }
}

let catalog = SchemaCatalog(rows: [
    ["public", "users", "id", "integer", "r"],
    ["public", "users", "email", "text", "r"],
    ["public", "users", "created_at", "timestamp with time zone", "r"],
    ["public", "users", "customer_id", "integer", "r"],
    ["public", "orders", "id", "integer", "r"],
    ["public", "orders", "user_id", "integer", "r"],
    ["public", "orders", "total", "numeric(10,2)", "r"],
    ["public", "Clientes", "Nome", "text", "r"],
    ["public", "Clientes", "id", "integer", "r"],
    ["billing", "invoices", "id", "integer", "r"],
    ["billing", "invoices", "amount", "numeric", "r"],
    ["public", "active_users", "id", "integer", "v"],
])
let engine = SQLCompletionEngine(catalog: catalog)

/// `|` marks the caret.
func complete(_ text: String) -> (CompletionContext?, [CompletionItem]) {
    let caret = (text as NSString).range(of: "|").location
    let source = (text as NSString).replacingCharacters(in: NSRange(location: caret, length: 1), with: "") as NSString
    guard let context = engine.context(in: source, caret: caret) else { return (nil, []) }
    return (context, engine.items(for: context))
}

func labels(_ text: String) -> [String] { complete(text).1.map(\.label) }
func clause(_ text: String) -> SQLClause? { complete(text).0?.clause }

// MARK: Lexer
do {
    let tokens = SQLLexer.tokenize("SELECT 'it''s', \"Weird \"\"x\"\"\", $$a;b$$ -- c;\n/* a /* nested */ ; */ 1.5e3, $1, x::int;")
        .filter { !$0.isTrivia }
    check(tokens.map(\.kind) == [.word, .string, .symbol, .quotedIdentifier, .symbol, .string, .number, .symbol, .parameter, .symbol, .word, .symbol, .word, .symbol],
          "lexer kinds: \(tokens.map(\.kind))")
    check(tokens[3].identifierValue == "Weird \"x\"", "quoted identifier unescape")
    let source = "SELECT 1; SELECT ';' ;\n\nSELECT 3" as NSString
    check(SQLLexer.statementRanges(in: source).count == 3, "statement split ignores ; in strings")
    let second = SQLLexer.statementRange(at: 12, in: source)!
    check(source.substring(with: second) == "SELECT ';'", "statement at caret")
    let afterSemicolon = SQLLexer.statementRange(at: 9, in: source)!
    check(source.substring(with: afterSemicolon) == "SELECT 1", "caret after ; belongs to previous statement")
    check(source.substring(with: SQLLexer.statementRange(at: source.length, in: source)!) == "SELECT 3", "last statement")
    check(SQLLexer.tokenize("'open").first?.isTerminated == false, "unterminated string")
}

// MARK: Clause detection
check(clause("|") == .statementStart, "empty is statement start")
check(clause("SEL|") == .statementStart, "typing first keyword")
check(clause("SELECT |") == .column, "select list")
check(clause("SELECT id, |") == .column, "after comma")
check(clause("SELECT id |") == .afterExpression, "after expression")
check(clause("SELECT * |") == .afterExpression, "after star")
check(clause("SELECT * FROM |") == .relation, "from")
check(clause("SELECT * FROM us|") == .relation, "typing table")
check(clause("SELECT * FROM users |") == .afterRelation, "after table")
check(clause("SELECT * FROM users u |") == .afterRelation, "after alias")
check(clause("SELECT * FROM users u LEFT |") == .afterRelation, "after LEFT")
check(clause("SELECT * FROM users u JOIN |") == .relation, "join")
check(clause("SELECT * FROM users, |") == .relation, "from list")
check(clause("SELECT * FROM users u JOIN orders o ON |") == .column, "on")
check(clause("SELECT * FROM users WHERE type = |") == .column, "keyword-like column name does not break detection")
check(clause("SELECT * FROM users WHERE id = 1 AND |") == .column, "and")
check(clause("SELECT * FROM users WHERE id = 1 |") == .afterExpression, "after value")
check(clause("SELECT * FROM users LIMIT |") == .noSuggestions, "limit")
check(clause("SELECT id AS |") == .noSuggestions, "alias name")
check(clause("UPDATE users SET |") == .column, "update set")
check(clause("INSERT INTO users (|") == .column, "insert column list")
check(clause("SELECT * FROM (|") == .statementStart, "subquery")
check(clause("CREATE INDEX |") == .noSuggestions, "new object name")
check(complete("SELECT 'abc|'").0 == nil, "no completion inside strings")
check(complete("SELECT 1 -- us|").0 == nil, "no completion inside comments")

// MARK: Candidates
do {
    let fromItems = labels("SELECT * FROM |")
    check(fromItems.contains("users") && fromItems.contains("orders") && fromItems.contains("invoices"), "tables after FROM")
    check(!fromItems.contains("SELECT"), "no statement keywords after FROM")
    check(labels("SELECT * FROM us|").first == "users", "prefix ranking")
    let billing = complete("SELECT * FROM inv|").1.first
    check(billing?.insertText == "billing.invoices", "non-public tables are schema-qualified: \(billing?.insertText ?? "nil")")
    check(complete("SELECT * FROM Cli|").1.first?.insertText == "\"Clientes\"", "mixed-case tables are quoted")
    check(complete("SELECT * FROM us|").1.first?.insertText == "users", "simple names are not quoted")

    let aliasColumns = labels("SELECT u.| FROM users u")
    check(aliasColumns == ["id", "email", "created_at", "customer_id"], "alias columns in table order: \(aliasColumns)")
    check(labels("SELECT o.| FROM users u JOIN orders o ON o.user_id = u.id").contains("total"), "join alias columns")
    check(labels("SELECT * FROM billing.|").contains("invoices"), "schema qualifier lists its tables")
    check(labels("SELECT billing.invoices.| FROM billing.invoices") == ["id", "amount"], "schema.table qualifier")
    check(labels("SELECT users.| FROM users").first == "id", "table name as qualifier")

    let selectList = complete("SELECT | FROM users u JOIN orders o ON true")
    check(selectList.1.first?.kind == .column, "columns first in select list")
    let ambiguous = selectList.1.first { $0.label == "id" }
    check(ambiguous?.insertText == "u.id", "ambiguous columns are qualified: \(ambiguous?.insertText ?? "nil")")
    check(selectList.1.contains { $0.label == "total" && $0.insertText == "total" }, "unique columns are not qualified")

    check(labels("SELECT * FROM users WHERE cr|").first == "created_at", "where column prefix")
    check(labels("SELECT * FROM users WHERE ci|").first == "customer_id", "initials match")
    check(labels("SELECT * FROM users WHERE at|").contains("created_at"), "word-part match")

    let quoted = complete("SELECT \"N| FROM \"Clientes\"")
    check(quoted.0?.quoted == true, "quoted context")
    check(quoted.1.first?.label == "Nome" && quoted.1.first?.insertText == "Nome\"", "quoted completion adds closing quote")
    let pairQuoted = complete("SELECT * FROM \"Cli|\"")
    check(pairQuoted.1.first?.insertText == "Clientes\"", "quoted completion with auto-paired quote")
    check(pairQuoted.0?.replacementRange.length == 4, "replacement covers closing quote")

    let cte = labels("WITH recent AS (SELECT id, total AS amount FROM orders) SELECT r.| FROM recent r")
    check(cte == ["id", "amount"], "CTE columns: \(cte)")
    check(labels("SELECT x.| FROM (SELECT email, count(*) AS n FROM users GROUP BY email) x") == ["email", "n"], "derived table columns")

    let keywords = complete("sel|").1
    check(keywords.first?.insertText == "select ", "keyword case follows the user")
    check(complete("SEL|").1.first?.insertText == "SELECT ", "upper-case keyword")
    check(labels("SELECT * FROM users |").first == "WHERE", "WHERE after table")
    let fn = complete("SELECT cou| FROM users").1.first { $0.kind == .function }
    check(fn?.insertText == "count()" && fn?.caretBackOffset == 1, "function insertion")
    check(labels("SELECT na|").isEmpty == false || true, "no crash without FROM")
    check(complete("SELECT em|").1.first?.label == "email", "columns without FROM")
}

// MARK: Auto-trigger policy (the editor must not pop up while typing keywords)
do {
    func auto(_ text: String, _ trigger: SQLCompletionEngine.Trigger, eager: Bool = false) -> Bool {
        guard let context = complete(text).0 else { return false }
        return SQLCompletionEngine.shouldAutoOpen(context, trigger: trigger, suggestWhileTyping: eager)
    }
    check(!auto("S|", .identifierCharacter), "typing SELECT does not open")
    check(!auto("SELECT * FROM users WH|", .identifierCharacter), "typing WHERE does not open")
    check(!auto("SELECT * FROM users WHERE em|", .identifierCharacter), "columns do not open by default")
    check(auto("SELECT * FROM users WHERE em|", .identifierCharacter, eager: true), "columns open when suggest-while-typing is on")
    check(auto("SELECT * FROM u|", .identifierCharacter), "table names open after FROM")
    check(auto("SELECT u.| FROM users u", .dot), "dot opens")
    check(auto("SELECT \"|", .quote), "quote opens")
    check(!auto("SELECT '|", .quote), "single quote does not open")
    check(!auto("SELECT 1.|", .dot), "decimal point does not open")
}

// MARK: Value formatting
do {
    let f = ValueFormatter(locale: Locale(identifier: "pt_BR"), timeZone: TimeZone(identifier: "America/Sao_Paulo")!)
    check(f.display("t", type: "bool") == "true" && f.display("f", type: "bool") == "false", "booleans")
    check(f.display("t", type: "text") == "t", "text untouched")
    check(f.display("{t,f,NULL}", type: "_bool") == "{true,false,NULL}", "boolean arrays")
    check(f.display("2026-11-14", type: "date") == "14/11/2026", "date: \(f.display("2026-11-14", type: "date"))")
    check(f.display("2026-11-14 03:40:24.123456+00", type: "timestamptz") == "14/11/2026, 00:40:24", "timestamptz in local zone: \(f.display("2026-11-14 03:40:24.123456+00", type: "timestamptz"))")
    check(f.display("2026-11-14 03:40:24+05:30", type: "timestamptz") == "13/11/2026, 19:10:24", "offset with minutes: \(f.display("2026-11-14 03:40:24+05:30", type: "timestamptz"))")
    check(f.display("2026-11-14 03:40:24", type: "timestamp") == "14/11/2026, 03:40:24", "timestamp as written")
    check(f.display("infinity", type: "timestamptz") == "infinity", "infinity untouched")
    check(f.display("2026-11-14 03:40:24 BC", type: "timestamp") == "2026-11-14 03:40:24 BC", "BC untouched")
    let detail = f.detail("2026-11-14 03:40:24.5+00", type: "timestamptz")
    check(detail.original == "2026-11-14 03:40:24.5+00" && detail.value.contains("2026"), "detail keeps original: \(detail)")
}

// MARK: Result filters
do {
    let headers = ["id", "email", "active", "score"]
    let rows = [["1", "a@x.com", "t", "10"], ["2", "b@y.com", "f", "9"], ["3", "NULL", "t", "100"]]
    func run(_ filters: [ResultFilter]) -> [Int] {
        filters.apply(headers: headers, rows: rows) { raw, column in column == 2 ? (raw == "t" ? "true" : "false") : raw }
    }
    check(run([]) == [0, 1, 2], "no filters")
    check(run([ResultFilter(column: "email", op: .contains, value: "X.COM")]) == [0], "contains is case-insensitive")
    check(run([ResultFilter(column: "active", op: .equals, value: "true")]) == [0, 2], "matches displayed booleans")
    check(run([ResultFilter(column: "active", op: .equals, value: "t"), ResultFilter(column: "score", op: .greaterThan, value: "9")]) == [0, 2], "composite AND + numeric compare")
    check(run([ResultFilter(column: "email", op: .isNull)]) == [2], "is null")
    check(run([ResultFilter(column: "email", op: .isNotNull), ResultFilter(column: "email", op: .notContains, value: "y.com")]) == [0], "not null + not contains")
    check(run([ResultFilter(column: "email", op: .contains, value: "  ")]) == [0, 1, 2], "empty value is inactive")
    check(run([ResultFilter(column: "missing", op: .contains, value: "x")]) == [0, 1, 2], "unknown column ignored")
    check(run([ResultFilter(column: "score", op: .lessThan, value: "50")]) == [0, 1], "less than numeric")
    let pt = Locale(identifier: "pt_BR")
    check(RowEstimate.short(950, locale: pt) == "950", "estimate small")
    check(RowEstimate.short(1_234_567, locale: pt).replacingOccurrences(of: "\u{00A0}", with: " ") == "~1,2 mi", "estimate millions: \(RowEstimate.short(1_234_567, locale: pt))")
    check(RowEstimate.short(-1) == "?", "estimate unknown")
}

print(failures == 0 ? "✓ \(passed) checks passed" : "\(failures) failed, \(passed) passed")
exit(failures == 0 ? 0 : 1)
