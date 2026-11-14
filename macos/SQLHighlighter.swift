import AppKit

/// Token-based syntax highlighting. Runs as the text storage delegate so
/// colors are refreshed for every edit (typing, paste, undo) without
/// touching the undo stack, and keywords inside strings or comments are
/// never colored as keywords.
@MainActor
final class SQLHighlighter: NSObject, NSTextStorageDelegate {
    var fontSize: CGFloat = 13 { didSet { if fontSize != oldValue { regularFont = Self.font(fontSize, .regular); keywordFont = Self.font(fontSize, .semibold) } } }
    /// Called with the fresh tokens after each pass so the editor can reuse
    /// them for completion and bracket matching.
    var tokensDidChange: (([SQLToken]) -> Void)?

    // Fonts are cached: creating an NSFont per keyword made large scripts
    // take over a second to highlight.
    private(set) var regularFont = SQLHighlighter.font(13, .regular)
    private(set) var keywordFont = SQLHighlighter.font(13, .semibold)
    private static func font(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont { .monospacedSystemFont(ofSize: size, weight: weight) }

    static let keywordColor = NSColor.systemBlue
    static let functionColor = NSColor.systemIndigo
    static let typeColor = NSColor.systemTeal
    static let stringColor = NSColor.systemOrange
    static let numberColor = NSColor.systemPurple
    static let commentColor = NSColor.secondaryLabelColor
    static let parameterColor = NSColor.systemPink
    static let identifierColor = NSColor.labelColor
    private static let functionNames = Set(SQLVocabulary.functions.map(\.name))

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated { highlight(textStorage) }
    }

    func highlight(_ storage: NSTextStorage) {
        let source = storage.string as NSString
        let tokens = SQLLexer.tokenize(source)
        let full = NSRange(location: 0, length: source.length)
        storage.setAttributes([.font: regularFont, .foregroundColor: Self.identifierColor], range: full)
        let significant = tokens.filter { !$0.isTrivia }
        for (position, token) in significant.enumerated() {
            switch token.kind {
            case .word:
                let upper = token.upper
                let next = position + 1 < significant.count ? significant[position + 1] : nil
                let previous = position > 0 ? significant[position - 1] : nil
                let qualified = previous?.text == "." || next?.text == "."
                if next?.text == "(" && !qualified && previous?.text != "::" && (!SQLVocabulary.keywords.contains(upper) || Self.functionNames.contains(token.text.lowercased())) {
                    storage.addAttribute(.foregroundColor, value: Self.functionColor, range: token.range)
                } else if previous?.text == "::" || (SQLVocabulary.types.contains(upper) && !qualified && (Self.precedesType(previous) || next?.kind == .string)) {
                    storage.addAttribute(.foregroundColor, value: Self.typeColor, range: token.range)
                } else if SQLVocabulary.keywords.contains(upper) && !qualified {
                    storage.addAttributes([.foregroundColor: Self.keywordColor, .font: keywordFont], range: token.range)
                }
            case .string:
                storage.addAttribute(.foregroundColor, value: Self.stringColor, range: token.range)
            case .number:
                storage.addAttribute(.foregroundColor, value: Self.numberColor, range: token.range)
            case .parameter:
                storage.addAttribute(.foregroundColor, value: Self.parameterColor, range: token.range)
            default:
                break
            }
        }
        for token in tokens where token.kind == .comment {
            storage.addAttribute(.foregroundColor, value: Self.commentColor, range: token.range)
        }
        tokensDidChange?(tokens)
    }

    /// Type names double as common column names (`date`, `text`), so they
    /// are only colored where a type is expected: after a column name in a
    /// definition (`created_at timestamptz`) or after `AS` in a cast.
    private static func precedesType(_ previous: SQLToken?) -> Bool {
        guard let previous else { return false }
        if previous.kind == .quotedIdentifier { return true }
        guard previous.kind == .word else { return false }
        let upper = previous.upper
        return upper == "AS" || SQLVocabulary.types.contains(upper) || !SQLVocabulary.keywords.contains(upper)
    }
}
