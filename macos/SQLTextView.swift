import AppKit

/// The SQL editor: syntax highlighting, context-aware autocomplete, auto
/// paired brackets/quotes, smart indentation, line comments, current-line
/// and bracket-match highlighting.
@MainActor
final class SQLTextView: NSTextView {
    static let indentUnit = "    "

    let highlighter = SQLHighlighter()
    private let popup = CompletionPopup()
    var engine = SQLCompletionEngine(catalog: .empty)
    /// When on, column names are also suggested while typing (2+ letters).
    var suggestWhileTyping = false

    private var cachedTokens: [SQLToken]?
    private var completionContext: CompletionContext?
    /// Start of the word whose suggestions the user dismissed with ⎋; auto
    /// suggestions stay quiet until they move on to another word.
    private var dismissedWordStart: Int?
    private var bracketHighlights: [NSRange] = []
    private var errorHighlight: NSRange?
    private var isApplyingEdit = false

    var fontSize: CGFloat {
        get { highlighter.fontSize }
        set {
            highlighter.fontSize = max(9, min(28, newValue))
            popup.fontSize = max(11, highlighter.fontSize - 1)
            font = highlighter.regularFont
            typingAttributes = [.font: highlighter.regularFont, .foregroundColor: NSColor.labelColor]
            if let storage = textStorage { highlighter.highlight(storage) }
            enclosingScrollView?.verticalRulerView?.needsDisplay = true
            needsDisplay = true
        }
    }

    var tokens: [SQLToken] {
        if let cachedTokens { return cachedTokens }
        let tokens = SQLLexer.tokenize(string as NSString)
        cachedTokens = tokens
        return tokens
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    convenience init() {
        // TextKit 1 is required for the line-number ruler and temporary
        // attributes used by the bracket and error highlights.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainerInset = NSSize(width: 4, height: 6)
        textContainer?.lineFragmentPadding = 4
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        insertionPointColor = .controlAccentColor
        textStorage?.delegate = highlighter
        highlighter.tokensDidChange = { [weak self] tokens in
            self?.cachedTokens = tokens
            self?.errorHighlight = nil  // any edit invalidates the error marker
        }
        popup.onAccept = { [weak self] item in self?.accept(item) }
        fontSize = 13
    }

    // MARK: - Text changes

    override var string: String {
        get { super.string }
        set { super.string = newValue; clearErrorHighlight() }
    }

    override func didChangeText() {
        super.didChangeText()
        clearErrorHighlight()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateBracketHighlight()
        setNeedsDisplay(visibleRect, avoidAdditionalLayout: true)
        if popup.isVisible, let context = completionContext, !isApplyingEdit {
            let caret = selectedRange()
            let word = context.replacementRange
            if caret.length > 0 || caret.location < word.location || caret.location > NSMaxRange(word) + 1 { hideCompletions() }
        }
    }

    override func resignFirstResponder() -> Bool {
        hideCompletions()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { hideCompletions() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseDown(with event: NSEvent) {
        hideCompletions()
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        hideCompletions()
        super.scrollWheel(with: event)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .control, event.charactersIgnoringModifiers == " " {
            showCompletions()
            return
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if popup.isVisible {
            switch selector {
            case #selector(moveUp(_:)): popup.moveSelection(by: -1); return
            case #selector(moveDown(_:)): popup.moveSelection(by: 1); return
            case #selector(scrollPageUp(_:)), #selector(pageUp(_:)): popup.moveSelection(by: -8); return
            case #selector(scrollPageDown(_:)), #selector(pageDown(_:)): popup.moveSelection(by: 8); return
            case #selector(insertNewline(_:)), #selector(insertTab(_:)):
                if let item = popup.selectedItem { accept(item); return }
            case #selector(cancelOperation(_:)), #selector(complete(_:)):
                dismissCompletions()
                return
            case #selector(deleteBackward(_:)), #selector(deleteForward(_:)):
                break
            default:
                hideCompletions()
            }
        }
        defer {
            // Keep the list in sync while deleting, and close it once the
            // word being completed is gone.
            if popup.isVisible, [#selector(deleteBackward(_:)), #selector(deleteForward(_:))].contains(selector) {
                if let context = currentContext(), context.replacementRange.length > 0 || !context.qualifier.isEmpty || context.quoted {
                    present(context: context, manual: false)
                } else {
                    hideCompletions()
                }
            }
        }
        switch selector {
        case #selector(complete(_:)):
            showCompletions()
        case #selector(insertNewline(_:)):
            insertSmartNewline()
        case #selector(insertTab(_:)):
            if selectionSpansLines() { shiftSelectedLines(outdent: false) } else { insertIndent() }
        case #selector(insertBacktab(_:)):
            shiftSelectedLines(outdent: true)
        case #selector(deleteBackward(_:)):
            if !deletePairIfNeeded() { super.doCommand(by: selector) }
        default:
            super.doCommand(by: selector)
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard !isApplyingEdit, !hasMarkedText(),
              let text = (string as? String) ?? (string as? NSAttributedString)?.string,
              text.utf16.count == 1 else {
            super.insertText(string, replacementRange: replacementRange)
            if !hasMarkedText() { hideCompletions() }
            return
        }
        if !handlePairing(text) {
            super.insertText(string, replacementRange: replacementRange)
        }
        afterTyping(text)
    }

    /// Decides whether to open, refresh or close the suggestion list after a
    /// character was typed.
    private func afterTyping(_ text: String) {
        guard let scalar = text.unicodeScalars.first else { return }
        let isIdentifier = SQLLexer.isIdentifierPart(unichar(truncatingIfNeeded: scalar.value))
        if popup.isVisible {
            if isIdentifier || text == "." || text == "\"" {
                refreshCompletions(manual: false)
            } else {
                hideCompletions()
            }
            return
        }
        let trigger: SQLCompletionEngine.Trigger
        switch text {
        case ".": trigger = .dot
        case "\"": trigger = .quote
        default:
            guard isIdentifier else { dismissedWordStart = nil; return }
            trigger = .identifierCharacter
        }
        guard let context = currentContext() else { return }
        if trigger != .identifierCharacter { dismissedWordStart = nil }
        if let dismissed = dismissedWordStart, dismissed == context.replacementRange.location { return }
        dismissedWordStart = nil
        guard SQLCompletionEngine.shouldAutoOpen(context, trigger: trigger, suggestWhileTyping: suggestWhileTyping) else { return }
        present(context: context, manual: false)
    }

    // MARK: - Completion

    @objc func showCompletions(_ sender: Any? = nil) {
        dismissedWordStart = nil
        refreshCompletions(manual: true)
    }

    private func currentContext() -> CompletionContext? {
        let selection = selectedRange()
        guard selection.length == 0 else { return nil }
        return engine.context(in: string as NSString, caret: selection.location, tokens: tokens)
    }

    private func refreshCompletions(manual: Bool) {
        guard let context = currentContext() else { hideCompletions(); return }
        present(context: context, manual: manual)
    }

    private func present(context: CompletionContext, manual: Bool) {
        let items = engine.items(for: context)
        // Nothing useful to show, or the word is already complete.
        let alreadyComplete = !manual && items.count == 1 && !context.quoted
            && items[0].label.caseInsensitiveCompare(context.prefix) == .orderedSame
        guard !items.isEmpty, !alreadyComplete, let window else {
            hideCompletions()
            if manual && items.isEmpty { NSSound.beep() }
            return
        }
        completionContext = context
        let anchorLocation = context.quoted ? max(0, context.replacementRange.location - 1) : context.replacementRange.location
        var anchor = firstRect(forCharacterRange: NSRange(location: anchorLocation, length: 0), actualRange: nil)
        if anchor.height == 0 { anchor.size.height = fontSize + 4 }
        popup.show(items: items, prefix: context.prefix, anchor: anchor, in: window)
    }

    func hideCompletions() {
        popup.hide()
        completionContext = nil
    }

    private func dismissCompletions() {
        dismissedWordStart = completionContext?.replacementRange.location
        hideCompletions()
    }

    private func accept(_ item: CompletionItem) {
        guard let context = currentContext() ?? completionContext else { hideCompletions(); return }
        let source = string as NSString
        let range = context.replacementRange
        let after = NSMaxRange(range) < source.length ? source.character(at: NSMaxRange(range)) : nil
        var insertion = item.insertText
        var caretBack = item.caretBackOffset
        if insertion.hasSuffix(" "), let after, SQLLexer.isWhitespace(after) || after == 41 || after == 44 || after == 59 {
            insertion.removeLast()  // don't double the space before `)`, `,`, `;`
        }
        var caretForward = 0
        if item.kind == .function, after == 40 {
            // `count|(x)`: reuse the parenthesis that is already there.
            insertion = String(insertion.dropLast(2))
            caretBack = 0
            caretForward = 1
        }
        hideCompletions()
        let end = range.location + insertion.utf16.count
        replace(range, with: insertion, selectAfter: NSRange(location: end - caretBack + caretForward, length: 0))
        if item.retrigger {
            DispatchQueue.main.async { [weak self] in self?.refreshCompletions(manual: false) }
        }
    }

    // MARK: - Editing helpers

    /// Replaces text as a single undoable edit.
    func replace(_ range: NSRange, with text: String, selectAfter selection: NSRange? = nil) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        isApplyingEdit = true
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        isApplyingEdit = false
        setSelectedRange(selection ?? NSRange(location: range.location + text.utf16.count, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    private func character(at index: Int) -> unichar? {
        let source = string as NSString
        return index >= 0 && index < source.length ? source.character(at: index) : nil
    }

    private func isInsideLiteral(at location: Int) -> Bool {
        guard let token = SQLLexer.token(at: location, in: tokens), location > token.range.location else { return false }
        switch token.kind {
        case .comment: return location < token.end || !token.isTerminated || token.text.hasPrefix("--")
        case .string, .quotedIdentifier: return location < token.end || !token.isTerminated
        default: return false
        }
    }

    /// Auto-closes brackets and quotes, wraps selections, and types over a
    /// closing character that is already there. Returns true when handled.
    private func handlePairing(_ text: String) -> Bool {
        let pairs: [String: String] = ["(": ")", "[": "]", "'": "'", "\"": "\""]
        let selection = selectedRange()
        let next = character(at: selection.location)
        let previous = character(at: selection.location - 1)

        if selection.length > 0, let close = pairs[text] {
            let selected = (string as NSString).substring(with: selection)
            replace(selection, with: text + selected + close, selectAfter: NSRange(location: selection.location + 1, length: selection.length))
            return true
        }
        guard selection.length == 0 else { return false }
        let typed = text.utf16.first!

        // Type over a closing character the editor inserted.
        if (text == ")" || text == "]"), next == typed {
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return true
        }
        if text == "'" || text == "\"" {
            if next == typed, let token = SQLLexer.token(at: selection.location + 1, in: tokens),
               token.isTerminated, token.end == selection.location + 1,
               token.kind == (text == "'" ? .string : .quotedIdentifier) {
                setSelectedRange(NSRange(location: selection.location + 1, length: 0))
                return true
            }
            if isInsideLiteral(at: selection.location) { return false }
            if let previous, SQLLexer.isIdentifierPart(previous) || previous == typed { return false }
            if let next, SQLLexer.isIdentifierPart(next) { return false }
            replace(selection, with: text + text, selectAfter: NSRange(location: selection.location + 1, length: 0))
            return true
        }
        if let close = pairs[text], text == "(" || text == "[" {
            if isInsideLiteral(at: selection.location) { return false }
            let closesNicely = next == nil || SQLLexer.isWhitespace(next!) || [41, 93, 44, 59].contains(next!)  // ) ] , ;
            guard closesNicely else { return false }
            replace(selection, with: text + close, selectAfter: NSRange(location: selection.location + 1, length: 0))
            return true
        }
        return false
    }

    /// Backspace between an empty pair removes both characters.
    private func deletePairIfNeeded() -> Bool {
        let selection = selectedRange()
        guard selection.length == 0, let previous = character(at: selection.location - 1), let next = character(at: selection.location) else { return false }
        let pairs: [unichar: unichar] = [40: 41, 91: 93, 39: 39, 34: 34]
        guard pairs[previous] == next else { return false }
        replace(NSRange(location: selection.location - 1, length: 2), with: "")
        return true
    }

    private func currentLineRange(_ location: Int) -> NSRange {
        (string as NSString).lineRange(for: NSRange(location: location, length: 0))
    }

    private func leadingWhitespace(ofLineAt location: Int) -> String {
        let source = string as NSString
        let line = currentLineRange(location)
        var end = line.location
        while end < NSMaxRange(line), let c = character(at: end), c == 32 || c == 9 { end += 1 }
        return source.substring(with: NSRange(location: line.location, length: end - line.location))
    }

    private func insertSmartNewline() {
        let selection = selectedRange()
        let lineStart = currentLineRange(selection.location).location
        let indentation = leadingWhitespace(ofLineAt: selection.location)
        // Trailing spaces before the caret are dropped.
        var start = selection.location
        while start > lineStart, let c = character(at: start - 1), c == 32 || c == 9 { start -= 1 }
        let range = NSRange(location: start, length: NSMaxRange(selection) - start)
        let opensBlock = character(at: start - 1) == 40  // (
        let closesNext = character(at: NSMaxRange(selection)) == 41  // )
        if opensBlock && closesNext {
            let inner = "\n" + indentation + Self.indentUnit
            replace(range, with: inner + "\n" + indentation, selectAfter: NSRange(location: start + inner.utf16.count, length: 0))
        } else if opensBlock {
            replace(range, with: "\n" + indentation + Self.indentUnit)
        } else {
            replace(range, with: "\n" + indentation)
        }
    }

    private func insertIndent() {
        let selection = selectedRange()
        let column = selection.location - currentLineRange(selection.location).location
        let width = Self.indentUnit.count - column % Self.indentUnit.count
        replace(selection, with: String(repeating: " ", count: width))
    }

    private func selectionSpansLines() -> Bool {
        let selection = selectedRange()
        guard selection.length > 0 else { return false }
        return (string as NSString).substring(with: selection).contains("\n")
    }

    private func selectedLinesRange() -> NSRange {
        let source = string as NSString
        var selection = selectedRange()
        // A selection ending at the start of a line does not include it.
        if selection.length > 0, character(at: NSMaxRange(selection) - 1) == 10 { selection.length -= 1 }
        return source.lineRange(for: selection)
    }

    private func transformSelectedLines(_ transform: ([String]) -> [String]) {
        let source = string as NSString
        let range = selectedLinesRange()
        var text = source.substring(with: range)
        let trailingNewline = text.hasSuffix("\n")
        if trailingNewline { text.removeLast() }
        let lines = text.components(separatedBy: "\n")
        var result = transform(lines).joined(separator: "\n")
        if trailingNewline { result += "\n" }
        let newLength = result.utf16.count - (trailingNewline ? 1 : 0)
        replace(range, with: result, selectAfter: NSRange(location: range.location, length: newLength))
    }

    func shiftSelectedLines(outdent: Bool) {
        transformSelectedLines { lines in
            lines.map { line in
                if !outdent { return line.isEmpty ? line : Self.indentUnit + line }
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                let spaces = line.prefix { $0 == " " }.count
                return String(line.dropFirst(min(spaces, Self.indentUnit.count)))
            }
        }
    }

    @objc func toggleLineComment(_ sender: Any?) {
        let hadSelection = selectedRange().length > 0
        let caret = selectedRange().location
        let lineStart = currentLineRange(caret).location
        var delta = 0
        transformSelectedLines { lines in
            let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let allCommented = !content.isEmpty && content.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
            let indent = content.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
            return lines.enumerated().map { index, line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
                if allCommented {
                    let leading = line.prefix { $0 == " " || $0 == "\t" }
                    var rest = line.dropFirst(leading.count).dropFirst(2)
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    if index == 0 { delta = rest.count - (line.count - leading.count) }
                    return String(leading) + rest
                }
                if index == 0 { delta = 3 }
                let head = line.prefix(indent)
                return head + "-- " + line.dropFirst(indent)
            }
        }
        if !hadSelection {
            // Keep the caret where it was and move to the next line, like
            // most SQL IDEs do for repeated ⌘/.
            let newCaret = max(lineStart, caret + delta)
            setSelectedRange(NSRange(location: min(newCaret, (string as NSString).length), length: 0))
        }
    }

    @objc func duplicateLine(_ sender: Any?) {
        let selection = selectedRange()
        let source = string as NSString
        if selection.length > 0 {
            let text = source.substring(with: selection)
            replace(NSRange(location: NSMaxRange(selection), length: 0), with: text, selectAfter: NSRange(location: NSMaxRange(selection), length: selection.length))
            return
        }
        let line = currentLineRange(selection.location)
        var text = source.substring(with: line)
        let offset = selection.location - line.location
        if !text.hasSuffix("\n") { text = "\n" + text; replace(NSRange(location: NSMaxRange(line), length: 0), with: text, selectAfter: NSRange(location: NSMaxRange(line) + 1 + offset, length: 0)); return }
        replace(NSRange(location: NSMaxRange(line), length: 0), with: text, selectAfter: NSRange(location: NSMaxRange(line) + offset, length: 0))
    }

    @objc func increaseEditorFont(_ sender: Any?) { fontSize += 1 }
    @objc func decreaseEditorFont(_ sender: Any?) { fontSize -= 1 }
    @objc func resetEditorFont(_ sender: Any?) { fontSize = 13 }

    // MARK: - Statements & errors

    /// The selection if there is one, otherwise the statement under the caret.
    func executableRange() -> NSRange? {
        let selection = selectedRange()
        let source = string as NSString
        if selection.length > 0 {
            let trimmed = SQLLexer.trim(selection, in: source)
            return trimmed.length > 0 ? trimmed : nil
        }
        return SQLLexer.statementRange(at: selection.location, in: source, tokens: tokens)
    }

    /// Briefly tints a range (used to show which statement ran).
    func flash(_ range: NSRange) {
        guard let layoutManager, NSMaxRange(range) <= (string as NSString).length else { return }
        let color = NSColor.controlAccentColor.withAlphaComponent(0.18)
        layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let layoutManager = self.layoutManager, NSMaxRange(range) <= (self.string as NSString).length else { return }
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            self.updateBracketHighlight()
        }
    }

    /// Underlines the token at a UTF-16 offset reported by PostgreSQL and
    /// moves the caret there. Cleared on the next edit.
    func markError(at location: Int) {
        let source = string as NSString
        guard location >= 0, location <= source.length, let layoutManager else { return }
        clearErrorHighlight()
        var range = NSRange(location: min(location, max(0, source.length - 1)), length: source.length > 0 ? 1 : 0)
        if let token = SQLLexer.token(at: location + 1, in: tokens), !token.isTrivia { range = token.range }
        guard range.length > 0 else { return }
        layoutManager.addTemporaryAttributes([
            .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
            .underlineColor: NSColor.systemRed,
            .backgroundColor: NSColor.systemRed.withAlphaComponent(0.12),
        ], forCharacterRange: range)
        errorHighlight = range
        setSelectedRange(NSRange(location: range.location, length: 0))
        scrollRangeToVisible(range)
    }

    private func clearErrorHighlight() {
        guard let layoutManager else { return }
        let all = NSRange(location: 0, length: (string as NSString).length)
        for key in [NSAttributedString.Key.underlineStyle, .underlineColor, .backgroundColor] {
            layoutManager.removeTemporaryAttribute(key, forCharacterRange: all)
        }
        errorHighlight = nil
        bracketHighlights = []
        updateBracketHighlight()
    }

    // MARK: - Visual aids

    private func updateBracketHighlight() {
        guard let layoutManager else { return }
        let length = (string as NSString).length
        for range in bracketHighlights where NSMaxRange(range) <= length {
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        }
        bracketHighlights = []
        if let errorHighlight, NSMaxRange(errorHighlight) <= length {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.12), forCharacterRange: errorHighlight)
        }
        let selection = selectedRange()
        guard selection.length == 0, length > 0, length < 500_000 else { return }
        let brackets = tokens.filter { $0.kind == .symbol && ($0.text == "(" || $0.text == ")") }
        let caret = selection.location
        guard let hit = brackets.first(where: { $0.range.location == caret - 1 || $0.range.location == caret }) else { return }
        guard let index = brackets.firstIndex(of: hit) else { return }
        var depth = 0
        var match: SQLToken?
        if hit.text == "(" {
            for token in brackets[index...] {
                depth += token.text == "(" ? 1 : -1
                if depth == 0 { match = token; break }
            }
        } else {
            for token in brackets[...index].reversed() {
                depth += token.text == ")" ? 1 : -1
                if depth == 0 { match = token; break }
            }
        }
        let color = match == nil ? NSColor.systemRed.withAlphaComponent(0.25) : NSColor.systemYellow.withAlphaComponent(0.35)
        for token in [hit, match].compactMap({ $0 }) {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: token.range)
            bracketHighlights.append(token.range)
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard selectedRange().length == 0, let layoutManager, window?.firstResponder === self else { return }
        let length = (string as NSString).length
        let caret = selectedRange().location
        var lineRect: NSRect
        if length == 0 || (caret == length && character(at: length - 1) == 10) {
            lineRect = layoutManager.extraLineFragmentRect
            if lineRect.isEmpty { lineRect = NSRect(x: 0, y: 0, width: bounds.width, height: fontSize + 4) }
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(caret, length - 1))
            lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
        }
        lineRect.origin.x = 0
        lineRect.size.width = bounds.width
        lineRect.origin.y += textContainerOrigin.y
        NSColor.controlAccentColor.withAlphaComponent(0.07).setFill()
        lineRect.intersection(rect).fill()
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.insertItem(.separator(), at: 0)
        let items: [(String, Selector)] = [
            ("Mostrar sugestões", #selector(showCompletions(_:))),
            ("Comentar/descomentar linhas", #selector(toggleLineComment(_:))),
            ("Duplicar linha", #selector(duplicateLine(_:))),
        ]
        for (title, action) in items.reversed() {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
        }
        return menu
    }
}
