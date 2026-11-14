import AppKit

/// Floating suggestion list shown under the caret. It never takes keyboard
/// focus: the editor forwards ↑ ↓ ⇞ ⇟ ↩ ⇥ ⎋ while it is visible.
@MainActor
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var items: [CompletionItem] = []
    private var prefix = ""
    private let panel: NSPanel
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let footer = NSTextField(labelWithString: "")
    private weak var parentWindow: NSWindow?
    var onAccept: ((CompletionItem) -> Void)?
    var fontSize: CGFloat = 12

    private let rowHeight: CGFloat = 22
    private let maxVisibleRows = 10
    private let width: CGFloat = 480
    private let footerHeight: CGFloat = 22

    var isVisible: Bool { panel.isVisible }
    var selectedItem: CompletionItem? {
        let row = tableView.selectedRow
        return row >= 0 && row < items.count ? items[row] : nil
    }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none

        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = background

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        if #available(macOS 11.0, *) { tableView.style = .plain }

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        footer.font = .systemFont(ofSize: 10.5)
        footer.textColor = .tertiaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(scrollView)
        background.addSubview(divider)
        background.addSubview(footer)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: background.topAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -2),
            divider.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -3),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -4),
        ])
    }

    /// Shows (or refreshes) the list. `anchor` is the screen rect of the
    /// start of the word being completed.
    func show(items: [CompletionItem], prefix: String, anchor: NSRect, in window: NSWindow) {
        let previous = selectedItem
        self.items = items
        self.prefix = prefix
        tableView.reloadData()
        let keepRow = previous.flatMap { old in items.firstIndex { $0.label == old.label && $0.kind == old.kind } }
        select(row: prefix.isEmpty ? (keepRow ?? 0) : 0)

        let visibleRows = CGFloat(min(items.count, maxVisibleRows))
        let height = visibleRows * rowHeight + footerHeight + 10
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: anchor.minX - 30, y: anchor.minY - height - 3)
        if origin.y < screen.minY { origin.y = anchor.maxY + 3 }
        origin.x = max(screen.minX + 4, min(origin.x, screen.maxX - width - 4))
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: height), display: true)
        if parentWindow !== window {
            parentWindow?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            parentWindow = window
        }
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func hide() {
        guard panel.isVisible else { return }
        parentWindow?.removeChildWindow(panel)
        parentWindow = nil
        panel.orderOut(nil)
        items = []
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        var row = tableView.selectedRow + delta
        if abs(delta) == 1 {
            row = (row + items.count) % items.count  // wrap around with arrows
        } else {
            row = max(0, min(items.count - 1, row))
        }
        select(row: row)
    }

    private func select(row: Int) {
        guard row >= 0, row < items.count else { updateFooter(); return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        updateFooter()
    }

    private func updateFooter() {
        let hint = "↩ ou ⇥ inserir · ⎋ fechar"
        if let item = selectedItem, !item.detail.isEmpty {
            footer.stringValue = "\(item.detail)   —   \(hint)"
        } else {
            footer.stringValue = hint
        }
    }

    @objc private func rowClicked() {
        guard let item = selectedItem else { return }
        onAccept?(item)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { EmphasizedRowView() }

    func tableViewSelectionDidChange(_ notification: Notification) { updateFooter() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: CompletionCellView.identifier, owner: nil) as? CompletionCellView) ?? CompletionCellView()
        if row < items.count { cell.configure(items[row], prefix: prefix, fontSize: fontSize) }
        return cell
    }
}

/// Keeps the selection blue even though the panel is never key.
private final class EmphasizedRowView: NSTableRowView {
    override var isEmphasized: Bool { get { true } set {} }
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 4, dy: 1)
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
    }
}

private final class CompletionCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("completion-cell")
    private let badge = NSTextField(labelWithString: "")
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    private var current: (item: CompletionItem, prefix: String, fontSize: CGFloat)?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { render() }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        badge.alignment = .center
        badge.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3
        badge.drawsBackground = true
        label.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingHead
        detail.alignment = .right
        detail.textColor = .secondaryLabelColor
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        for view in [badge, label, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 16),
            badge.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: CompletionItem, prefix: String, fontSize: CGFloat) {
        current = (item, prefix, fontSize)
        render()
    }

    private func render() {
        guard let (item, prefix, fontSize) = current else { return }
        let selected = backgroundStyle == .emphasized
        let textColor: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
        badge.stringValue = item.kind.badge
        badge.backgroundColor = Self.color(for: item.kind)
        detail.stringValue = item.detail
        detail.font = .systemFont(ofSize: max(10, fontSize - 1.5))
        detail.textColor = selected ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let text = NSMutableAttributedString(string: item.label, attributes: [.font: font, .foregroundColor: textColor])
        // Bold the characters that matched what the user typed.
        if !prefix.isEmpty {
            let range = (item.label as NSString).range(of: prefix, options: [.caseInsensitive])
            if range.location != NSNotFound {
                text.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold), range: range)
            }
        }
        label.attributedStringValue = text
    }

    private static func color(for kind: CompletionKind) -> NSColor {
        switch kind {
        case .column: return .systemOrange
        case .alias: return .systemGray
        case .table: return .systemBlue
        case .view: return .systemTeal
        case .schema: return .systemBrown
        case .function: return .systemIndigo
        case .keyword: return .systemPurple
        }
    }
}
