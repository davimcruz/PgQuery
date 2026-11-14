import AppKit

/// UI for composite result filters: "+ Filtro" adds a row (column,
/// operator, value, ×); every row narrows the results (AND).
@MainActor
final class ResultFilterBar: NSObject, NSSearchFieldDelegate {
    let view = NSStackView()
    private(set) var filters: [ResultFilter] = []
    var onChange: (() -> Void)?

    private var headers: [String] = []
    private let addButton = PointerButton(title: "Filtro", target: nil, action: nil)
    private let clearButton = PointerButton(title: "Limpar filtros", target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")
    private let header = NSStackView()
    private var rowViews: [NSStackView] = []

    override init() {
        super.init()
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 6
        view.translatesAutoresizingMaskIntoConstraints = false

        addButton.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: "Adicionar filtro")
        addButton.imagePosition = .imageLeading
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addFilterMenu(_:))
        addButton.toolTip = "Adicionar um filtro. Vários filtros são combinados (todos precisam bater)."
        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearAll(_:))
        clearButton.isHidden = true
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        [addButton, clearButton, summary].forEach(header.addArrangedSubview)
        view.addArrangedSubview(header)
        updateEnabled()
    }

    /// Called when a new result arrives. Filters on columns that still
    /// exist are kept, so re-running a query keeps its filters.
    func setHeaders(_ headers: [String]) {
        self.headers = headers
        let kept = filters.filter { headers.contains($0.column) }
        if kept != filters { filters = kept; rebuildRows() } else { refreshColumnMenus() }
        updateEnabled()
    }

    func updateSummary(visible: Int, total: Int) {
        let active = filters.filter(\.isActive).count
        summary.stringValue = active > 0 ? "\(visible) de \(total) linhas" : ""
    }

    func removeAll() {
        filters = []
        rebuildRows()
    }

    private func updateEnabled() {
        addButton.isEnabled = !headers.isEmpty
        clearButton.isHidden = filters.count < 2
    }

    // MARK: Actions

    @objc private func addFilterMenu(_ sender: NSButton) {
        let menu = NSMenu()
        for header in headers {
            let item = NSMenuItem(title: header, action: #selector(addFilter(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = header
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func addFilter(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? String else { return }
        filters.append(ResultFilter(column: column))
        rebuildRows()
        if let field = rowViews.last?.arrangedSubviews.first(where: { $0 is NSSearchField }) {
            view.window?.makeFirstResponder(field)
        }
    }

    @objc private func clearAll(_ sender: Any?) {
        removeAll()
        onChange?()
    }

    @objc private func removeFilter(_ sender: NSButton) {
        guard sender.tag < filters.count else { return }
        filters.remove(at: sender.tag)
        rebuildRows()
        onChange?()
    }

    @objc private func columnChanged(_ sender: NSPopUpButton) {
        guard sender.tag < filters.count, let title = sender.titleOfSelectedItem else { return }
        filters[sender.tag].column = title
        onChange?()
    }

    @objc private func operatorChanged(_ sender: NSPopUpButton) {
        guard sender.tag < filters.count, sender.indexOfSelectedItem >= 0 else { return }
        filters[sender.tag].op = FilterOperator.allCases[sender.indexOfSelectedItem]
        if let row = rowViews[safe: sender.tag], let field = row.arrangedSubviews.first(where: { $0 is NSSearchField }) {
            field.isHidden = !filters[sender.tag].op.needsValue
        }
        onChange?()
    }

    @objc private func valueChanged(_ sender: NSSearchField) {
        guard sender.tag < filters.count else { return }
        filters[sender.tag].value = sender.stringValue
        onChange?()
    }

    // MARK: Rows

    private func refreshColumnMenus() {
        for (index, row) in rowViews.enumerated() {
            guard let popup = row.arrangedSubviews.first(where: { $0 is NSPopUpButton }) as? NSPopUpButton, index < filters.count else { continue }
            popup.removeAllItems()
            popup.addItems(withTitles: headers)
            popup.selectItem(withTitle: filters[index].column)
        }
    }

    private func rebuildRows() {
        for row in rowViews { view.removeArrangedSubview(row); row.removeFromSuperview() }
        rowViews = filters.enumerated().map { index, filter in makeRow(index: index, filter: filter) }
        rowViews.forEach(view.addArrangedSubview)
        updateEnabled()
    }

    private func makeRow(index: Int, filter: ResultFilter) -> NSStackView {
        let column = PointerPopupButton()
        column.addItems(withTitles: headers)
        column.selectItem(withTitle: filter.column)
        column.tag = index
        column.target = self
        column.action = #selector(columnChanged(_:))
        column.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true

        let op = PointerPopupButton()
        op.addItems(withTitles: FilterOperator.allCases.map(\.title))
        op.selectItem(at: FilterOperator.allCases.firstIndex(of: filter.op) ?? 0)
        op.tag = index
        op.target = self
        op.action = #selector(operatorChanged(_:))

        let field = NSSearchField()
        field.placeholderString = "valor…"
        field.stringValue = filter.value
        field.tag = index
        field.target = self
        field.action = #selector(valueChanged(_:))
        field.sendsSearchStringImmediately = true
        field.isHidden = !filter.op.needsValue
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let remove = PointerButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remover filtro")!, target: self, action: #selector(removeFilter(_:)))
        remove.isBordered = false
        remove.imagePosition = .imageOnly
        remove.contentTintColor = .secondaryLabelColor
        remove.toolTip = "Remover este filtro"
        remove.tag = index

        let label = NSTextField(labelWithString: index == 0 ? "onde" : "e")
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 11)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 34).isActive = true

        let row = NSStackView(views: [label, column, op, field, remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { index >= 0 && index < count ? self[index] : nil }
}
