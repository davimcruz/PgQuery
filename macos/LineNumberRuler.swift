import AppKit

/// Gutter with line numbers for the SQL editor. Wrapped lines show a number
/// only on their first visual line; the caret's line is emphasized.
@MainActor
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
        NotificationCenter.default.addObserver(self, selector: #selector(contentChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(contentChanged), name: NSText.didChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(contentChanged), name: NSTextView.didChangeSelectionNotification, object: textView)
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func contentChanged(_ notification: Notification) {
        updateThickness()
        needsDisplay = true
    }

    private var font: NSFont {
        let size = max(9, (textView?.font?.pointSize ?? 13) - 2)
        return .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    private func updateThickness() {
        guard let textView else { return }
        let source = textView.string as NSString
        var lines = 1
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: [.byLines, .substringNotRequired]) { _, _, _, _ in lines += 1 }
        let digits = max(2, String(lines).count)
        let width = CGFloat(digits) * ("8" as NSString).size(withAttributes: [.font: font]).width + 18
        if abs(width - ruleThickness) > 0.5 { ruleThickness = width }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let source = textView.string as NSString
        let visible = scrollView?.contentView.bounds ?? textView.visibleRect
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let caretLine = lineNumber(at: textView.selectedRange().location, in: source)
        var number = lineNumber(at: characters.location, in: source)
        let inset = textView.textContainerOrigin.y
        let regular: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let current: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]

        func draw(_ number: Int, fragmentY: CGFloat, fragmentHeight: CGFloat) {
            let label = "\(number)" as NSString
            let attributes = number == caretLine ? current : regular
            let size = label.size(withAttributes: attributes)
            let y = convert(NSPoint(x: 0, y: fragmentY + inset), from: textView).y
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (fragmentHeight - size.height) / 2), withAttributes: attributes)
        }

        var index = characters.location
        while index < NSMaxRange(characters) || (index == characters.location && source.length == 0) {
            guard source.length > 0 else { break }
            let line = source.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layoutManager.glyphIndexForCharacter(at: line.location)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            draw(number, fragmentY: fragment.minY, fragmentHeight: fragment.height)
            number += 1
            index = NSMaxRange(line)
            if line.length == 0 { break }
        }
        // The empty last line after a trailing newline (or an empty editor).
        let extra = layoutManager.extraLineFragmentRect
        if !extra.isEmpty, NSMaxRange(characters) >= source.length {
            draw(lineNumber(at: source.length, in: source), fragmentY: extra.minY, fragmentHeight: extra.height)
        }
    }

    private func lineNumber(at location: Int, in source: NSString) -> Int {
        let end = min(location, source.length)
        var count = 1
        var searchRange = NSRange(location: 0, length: end)
        while true {
            let found = source.range(of: "\n", options: .literal, range: searchRange)
            if found.location == NSNotFound { break }
            count += 1
            searchRange = NSRange(location: NSMaxRange(found), length: end - NSMaxRange(found))
        }
        return count
    }
}
