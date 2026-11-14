import Foundation

/// A small PostgreSQL-aware tokenizer shared by syntax highlighting,
/// statement detection and autocomplete. It works on UTF-16 offsets so its
/// ranges can be used directly with NSString / NSTextStorage.
enum SQLTokenKind: Equatable {
    case word            // bare identifier or keyword
    case quotedIdentifier
    case string
    case number
    case comment
    case parameter       // $1, :name
    case symbol          // operators and punctuation
    case whitespace
}

struct SQLToken: Equatable {
    var kind: SQLTokenKind
    var range: NSRange
    var text: String
    /// False for strings, quoted identifiers and block comments that reach
    /// the end of the input without being closed.
    var isTerminated = true

    var upper: String { text.uppercased() }
    var end: Int { range.location + range.length }
    var isTrivia: Bool { kind == .whitespace || kind == .comment }

    /// The identifier value: unquoted words are folded to lower case like
    /// PostgreSQL does; quoted identifiers keep their exact spelling.
    var identifierValue: String? {
        switch kind {
        case .word: return text.lowercased()
        case .quotedIdentifier:
            var inner = text.dropFirst()
            if isTerminated, inner.hasSuffix("\"") { inner = inner.dropLast() }
            return String(inner).replacingOccurrences(of: "\"\"", with: "\"")
        default: return nil
        }
    }
}

enum SQLLexer {
    static func tokenize(_ source: String) -> [SQLToken] {
        tokenize(source as NSString)
    }

    static func tokenize(_ source: NSString) -> [SQLToken] {
        let length = source.length
        guard length > 0 else { return [] }
        var chars = [unichar](repeating: 0, count: length)
        source.getCharacters(&chars, range: NSRange(location: 0, length: length))
        var tokens: [SQLToken] = []
        tokens.reserveCapacity(length / 3)
        var index = 0

        func peek(_ offset: Int) -> unichar? {
            let position = index + offset
            return position < length ? chars[position] : nil
        }

        func emit(_ kind: SQLTokenKind, from start: Int, terminated: Bool = true) {
            let range = NSRange(location: start, length: index - start)
            tokens.append(SQLToken(kind: kind, range: range, text: source.substring(with: range), isTerminated: terminated))
        }

        while index < length {
            let start = index
            let c = chars[index]

            if isWhitespace(c) {
                while index < length, isWhitespace(chars[index]) { index += 1 }
                emit(.whitespace, from: start)
            } else if c == dash, peek(1) == dash {
                while index < length, chars[index] != newline { index += 1 }
                emit(.comment, from: start)
            } else if c == slash, peek(1) == star {
                // PostgreSQL block comments nest.
                index += 2
                var depth = 1
                while index < length, depth > 0 {
                    if chars[index] == slash, peek(1) == star { depth += 1; index += 2 }
                    else if chars[index] == star, peek(1) == slash { depth -= 1; index += 2 }
                    else { index += 1 }
                }
                emit(.comment, from: start, terminated: depth == 0)
            } else if c == singleQuote || ((c == upperE || c == lowerE) && peek(1) == singleQuote) {
                let escapes = c != singleQuote
                index += escapes ? 2 : 1
                var closed = false
                while index < length {
                    let ch = chars[index]
                    if escapes, ch == backslash { index = min(index + 2, length); continue }
                    if ch == singleQuote {
                        if peek(1) == singleQuote { index += 2; continue }
                        index += 1
                        closed = true
                        break
                    }
                    index += 1
                }
                emit(.string, from: start, terminated: closed)
            } else if c == doubleQuote {
                index += 1
                var closed = false
                while index < length {
                    if chars[index] == doubleQuote {
                        if peek(1) == doubleQuote { index += 2; continue }
                        index += 1
                        closed = true
                        break
                    }
                    index += 1
                }
                emit(.quotedIdentifier, from: start, terminated: closed)
            } else if c == dollar, let tagEnd = dollarQuoteTagEnd(chars, from: index) {
                // Dollar-quoted string: $$ ... $$ or $tag$ ... $tag$
                let tag = Array(chars[index...tagEnd])
                index = tagEnd + 1
                var closed = false
                while index < length {
                    if chars[index] == dollar, index + tag.count <= length, Array(chars[index..<(index + tag.count)]) == tag {
                        index += tag.count
                        closed = true
                        break
                    }
                    index += 1
                }
                emit(.string, from: start, terminated: closed)
            } else if c == dollar, let next = peek(1), isDigit(next) {
                index += 1
                while index < length, isDigit(chars[index]) { index += 1 }
                emit(.parameter, from: start)
            } else if c == colon, let next = peek(1), isIdentifierStart(next), (start == 0 || chars[start - 1] != colon) {
                index += 1
                while index < length, isIdentifierPart(chars[index]) { index += 1 }
                emit(.parameter, from: start)
            } else if isDigit(c) || (c == dot && peek(1).map(isDigit) == true) {
                while index < length, isDigit(chars[index]) || chars[index] == dot || chars[index] == underscore { index += 1 }
                if index < length, chars[index] == upperE || chars[index] == lowerE,
                   let next = peek(1), isDigit(next) || ((next == plus || next == dash) && peek(2).map(isDigit) == true) {
                    index += 2
                    while index < length, isDigit(chars[index]) { index += 1 }
                }
                emit(.number, from: start)
            } else if isIdentifierStart(c) {
                index += 1
                while index < length, isIdentifierPart(chars[index]) { index += 1 }
                emit(.word, from: start)
            } else {
                // Group common multi-character operators so `::`, `<>`, `>=`,
                // `->>` read as a single symbol.
                index += 1
                if index < length,
                   ["::", "<>", "!=", ">=", "<=", "||", "->", "=>", "~~", "@>", "<@", "&&"].contains(String(utf16CodeUnits: [c, chars[index]], count: 2)) {
                    let two = String(utf16CodeUnits: [c, chars[index]], count: 2)
                    index += 1
                    if two == "->", index < length, chars[index] == greaterThan { index += 1 }
                }
                emit(.symbol, from: start)
            }
        }
        return tokens
    }

    /// Ranges of the top-level statements (split on `;` outside strings and
    /// comments). Each range excludes the terminating semicolon.
    static func statementRanges(in source: NSString, tokens: [SQLToken]? = nil) -> [NSRange] {
        let tokens = tokens ?? tokenize(source)
        var ranges: [NSRange] = []
        var start = 0
        for token in tokens where token.kind == .symbol && token.text == ";" {
            ranges.append(NSRange(location: start, length: token.range.location - start))
            start = token.end
        }
        ranges.append(NSRange(location: start, length: source.length - start))
        return ranges
    }

    /// The statement the caret belongs to, trimmed of surrounding whitespace.
    /// A caret right after a `;` (or on the blank space that follows it on
    /// the same line) still belongs to the statement that just ended.
    static func statementRange(at caret: Int, in source: NSString, tokens: [SQLToken]? = nil) -> NSRange? {
        let ranges = statementRanges(in: source, tokens: tokens)
        let nonEmpty = ranges.compactMap { range -> (NSRange, NSRange)? in
            let trimmed = trim(range, in: source)
            return trimmed.length > 0 ? (range, trimmed) : nil
        }
        guard !nonEmpty.isEmpty else { return nil }
        if let hit = nonEmpty.first(where: { caret >= $0.1.location && caret <= $0.1.location + $0.1.length }) {
            return hit.1
        }
        // Caret sits in whitespace between statements: prefer the previous
        // statement when it ends on the caret's line, otherwise the next one.
        let lineStart = source.lineRange(for: NSRange(location: min(caret, source.length), length: 0)).location
        if let previous = nonEmpty.last(where: { $0.1.location + $0.1.length <= caret }),
           previous.1.location + previous.1.length >= lineStart {
            return previous.1
        }
        if let next = nonEmpty.first(where: { $0.1.location >= caret }) { return next.1 }
        return nonEmpty.last?.1
    }

    static func trim(_ range: NSRange, in source: NSString) -> NSRange {
        var start = range.location
        var end = range.location + range.length
        while start < end, isWhitespace(source.character(at: start)) { start += 1 }
        while end > start, isWhitespace(source.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    static func token(at offset: Int, in tokens: [SQLToken]) -> SQLToken? {
        // The token that contains `offset`, treating a caret at the very end
        // of a token as inside it (that is where typing happens).
        var low = 0
        var high = tokens.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let token = tokens[mid]
            if offset <= token.range.location { high = mid - 1 }
            else if offset > token.end { low = mid + 1 }
            else { return token }
        }
        return nil
    }

    // MARK: - Character classes

    static func isWhitespace(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 || c == 11 || c == 0xA0 }
    static func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
    static func isIdentifierStart(_ c: unichar) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == underscore || c >= 128 && !isWhitespace(c) && c != 0x2028 && c != 0x2029
    }
    static func isIdentifierPart(_ c: unichar) -> Bool { isIdentifierStart(c) || isDigit(c) || c == dollar }

    private static func dollarQuoteTagEnd(_ chars: [unichar], from start: Int) -> Int? {
        var index = start + 1
        if index < chars.count, chars[index] == dollar { return index }
        guard index < chars.count, isIdentifierStart(chars[index]) else { return nil }
        while index < chars.count, chars[index] != dollar {
            guard isIdentifierPart(chars[index]) && chars[index] != dollar else { return nil }
            index += 1
        }
        return index < chars.count ? index : nil
    }
}

private let newline: unichar = 10
private let dash: unichar = 45
private let slash: unichar = 47
private let star: unichar = 42
private let singleQuote: unichar = 39
private let doubleQuote: unichar = 34
private let backslash: unichar = 92
private let dollar: unichar = 36
private let colon: unichar = 58
private let dot: unichar = 46
private let plus: unichar = 43
private let underscore: unichar = 95
private let upperE: unichar = 69
private let lowerE: unichar = 101
private let greaterThan: unichar = 62
