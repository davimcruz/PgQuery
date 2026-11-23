import AppKit

/// Read-only text view for EXPLAIN output: the grid truncates long plan
/// lines and cannot select across rows, a text view can do both.
@MainActor
final class PlanView: NSTextView {
    private(set) var planText = ""

    convenience init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        configure()
    }

    private func configure() {
        isEditable = false
        isSelectable = true
        usesFindBar = true
        isRichText = true
        textContainerInset = NSSize(width: 8, height: 8)
        // No wrapping: long plan lines scroll horizontally instead.
        isHorizontallyResizable = true
        isVerticallyResizable = true
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = false
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) { super.init(frame: frame, textContainer: textContainer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// EXPLAIN returns one column named "QUERY PLAN", one text line per row
    /// (a single multi-line cell for FORMAT JSON/XML/YAML).
    static func isPlan(headers: [String], rows: [[String]]) -> Bool {
        headers.count == 1 && headers[0].caseInsensitiveCompare("QUERY PLAN") == .orderedSame && !rows.isEmpty
    }

    func show(rows: [[String]]) {
        let text = rows.compactMap(\.first).joined(separator: "\n")
        guard text != planText else { return }
        planText = text
        textStorage?.setAttributedString(Self.styled(text))
        scroll(.zero)
    }

    static func styled(_ text: String) -> NSAttributedString {
        let regular = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        let out = NSMutableAttributedString(string: text, attributes: [.font: regular, .foregroundColor: NSColor.labelColor])
        func mark(_ pattern: String, _ attributes: [NSAttributedString.Key: Any]) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { out.addAttributes(attributes, range: match.range) }
        }
        mark(#"\((?:cost|actual time|never executed)[^)]*\)"#, [.foregroundColor: NSColor.secondaryLabelColor])  // numbers dimmed
        mark(#"^\s*(?:->\s+)?\w+(?: \w+)*?(?=\s+(?:on|using)\s|\s+\()"#, [.font: bold])                            // node names
        mark(#"Seq Scan"#, [.foregroundColor: NSColor.systemOrange])                                               // often the thing to fix
        mark(#"^(?:Planning|Execution) Time:.*$"#, [.font: bold, .foregroundColor: NSColor.systemGreen])
        return out
    }
}
