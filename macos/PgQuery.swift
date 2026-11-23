import AppKit
import Foundation
import Darwin
import Sparkle

@MainActor
private final class PgQueryUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var updateAvailabilityChanged: ((Bool) -> Void)?

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateAvailabilityChanged?(true)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        updateAvailabilityChanged?(false)
    }
}

@MainActor
class PointerTableView: NSTableView {
    private var pointerTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        NSCursor.pointingHand.set()
        if row(at: point) < 0 && headerView?.frame.contains(point) != true { NSCursor.arrow.set() }
    }

    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
}

@MainActor
final class ResultsGridView: PointerTableView {
    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        if clickedRow >= 0 && !selectedRowIndexes.contains(clickedRow) {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        super.rightMouseDown(with: event)
    }
}

/// Cursor rects are AppKit's own mechanism for hover cursors: they survive
/// scrolling, relayout and views that are rebuilt under the mouse, unlike a
/// tracking area that sets the cursor once on entry. Disabled controls keep
/// the arrow because they cannot be clicked.
@MainActor
class PointerButton: NSButton {
    override var isEnabled: Bool { didSet { window?.invalidateCursorRects(for: self) } }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.invalidateCursorRects(for: self) }
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

private final class DetailDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class PointerPopupButton: NSPopUpButton {
    override var isEnabled: Bool { didSet { window?.invalidateCursorRects(for: self) } }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.invalidateCursorRects(for: self) }
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

@MainActor
final class PointerSegmentedControl: NSSegmentedControl {
    override var isEnabled: Bool { didSet { window?.invalidateCursorRects(for: self) } }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.invalidateCursorRects(for: self) }
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

/// Row view for the results grid that closes the last column with a grid
/// line (row backgrounds are drawn over the table's own grid).
final class ResultsRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let table = superview as? NSTableView, table.numberOfColumns > 0,
              table.gridStyleMask.contains(.solidVerticalGridLineMask) else { return }
        let x = table.rect(ofColumn: table.numberOfColumns - 1).maxX - 0.5 - frame.minX
        table.gridColor.setFill()
        NSRect(x: x, y: bounds.minY, width: 1, height: bounds.height).fill()
    }
}

/// Sidebar row: table name with its approximate row count on the right.
final class TableListCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("table-list-cell")
    private let name = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingTail
        count.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        count.textColor = .tertiaryLabelColor
        count.alignment = .right
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        count.setContentHuggingPriority(.required, for: .horizontal)
        for view in [name, count] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        textField = name
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, count: String) {
        self.name.stringValue = name
        self.count.stringValue = count
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { count.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .tertiaryLabelColor }
    }
}

/// A result set kept so foreign-key navigation can go back to it.
struct ResultSnapshot {
    var headers: [String]
    var types: [String]
    var foreignKeys: [[String]]
    var rows: [[String]]
    var note: String
    var selectedRow: Int?
}

@MainActor
@main
final class PgQueryApp: NSObject, NSApplicationDelegate, NSTextViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private let connectionField = NSTextField()
    private let filterField = NSTextField()
    private let queryView = SQLTextView()
    private let tableListView = PointerTableView()
    private let resultsTableView = ResultsGridView()
    private let filterBar = ResultFilterBar()
    private let detailStack = NSStackView()
    private var detailPanel: NSVisualEffectView!
    private var detailScrollView: NSScrollView!
    private var sqlScrollView: NSScrollView!
    private var sqlRunButton: NSButton!
    private var sqlRunStatementButton: NSButton!
    private var copyResultsButton: NSButton!
    private var clearResultsButton: NSButton!
    private var hasExecutedQuery = false
    private var updaterController: SPUStandardUpdaterController?
    private var updaterDelegate: PgQueryUpdaterDelegate?
    private var updateMenuItem: NSMenuItem?
    private var sqlMinimumHeightConstraint: NSLayoutConstraint!
    private var sqlResultsEqualHeightConstraint: NSLayoutConstraint!
    private var sqlEditorVisible = true
    private let connectionSummaryField = NSTextField(labelWithString: "Conectado")
    private let resultNote = NSTextField(labelWithString: "")
    private let metricsField = NSTextField(labelWithString: "Este app · CPU — · Memória —")
    private let tlsWarningField = NSTextField(labelWithString: "")
    private let connectionBar = NSStackView()
    private let connectedBar = NSStackView()
    private var tables: [String] = []
    /// Approximate row count per `schema.table` (planner statistics).
    private var tableEstimates: [String: Int64] = [:]
    private var previewTable: String?
    private var lastExecutedSQL = ""
    private var lastExecutedOffset = 0
    private var saveSQLWorkItem: DispatchWorkItem?
    private var suggestWhileTypingItem: NSMenuItem?
    private var resultHeaders: [String] = []
    private var resultRows: [[String]] = []
    /// PostgreSQL type name per result column (empty when unknown).
    private var resultTypes: [String] = []
    /// `[schema, table, column]` a result column references, or `[]`.
    private var resultForeignKeys: [[String]] = []
    private let valueFormatter = ValueFormatter()
    /// Results to return to with "Voltar" after following foreign keys.
    private var navigationStack: [ResultSnapshot] = []
    private var openDetailsOnNextResult = false
    private let detailBackButton = PointerButton(title: "Voltar", target: nil, action: nil)
    private var resultSortColumn: Int?
    private var resultSortAscending = true
    private var connectionURL = ""
    private var hasConnectedOnce = false
    private var settingsWindow: NSWindow?
    private let secureURLField = NSSecureTextField()
    private let visibleURLField = NSTextField()
    private let revealURLButton = PointerButton(checkboxWithTitle: "Mostrar URL", target: nil, action: nil)
    private let connectionModePicker = PointerSegmentedControl(labels: ["URL", "Parâmetros"], trackingMode: .selectOne, target: nil, action: nil)
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let databaseField = NSTextField()
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let sslModeField = PointerPopupButton()
    private let connectionParameterStack = NSStackView()
    private var connectionURLStack: NSStackView!
    private let appShell = NSStackView()
    private var rootFullWidthConstraint: NSLayoutConstraint!
    private var rootDrawerWidthConstraint: NSLayoutConstraint!
    private var detailPanelWidthConstraint: NSLayoutConstraint!
    private var lastCpuNs: UInt64?
    private var lastSampleNs: UInt64?

    static func main() {
        let app = NSApplication.shared
        let delegate = PgQueryApp()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        installBackendNotification()
        configureUpdater()
        if let savedSQL = UserDefaults.standard.string(forKey: "pgquery.last-sql") {
            queryView.string = savedSQL
            queryView.setSelectedRange(NSRange(location: (savedSQL as NSString).length, length: 0))
        }
        if let savedURL = loadSavedConnectionURL() {
            connectionURL = savedURL
            connectionField.stringValue = savedURL
            hasConnectedOnce = true
            setConnected(false)
            connect()
        }
        // The Rust worker wakes the UI when an event is ready, so there is no
        // fast polling timer (it kept the CPU waking ~30×/s while idle). This
        // slow timer only refreshes the stats and drains events as a safety
        // net; its tolerance lets macOS coalesce the wakeup.
        let timer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(slowTimer(_:)), userInfo: nil, repeats: true)
        timer.tolerance = 0.5
    }

    private static weak var current: PgQueryApp?

    /// Registered before the first connection so no event is missed.
    private func installBackendNotification() {
        PgQueryApp.current = self
        pg_set_notify {
            // Runs on the Rust worker thread: hop to the main thread.
            DispatchQueue.main.async { MainActor.assumeIsolated { PgQueryApp.current?.drainBackend() } }
        }
    }

    /// Reads every pending backend event (connecting emits several in a row).
    private func drainBackend() {
        for _ in 0..<256 { guard pollBackend() else { return } }
        DispatchQueue.main.async { [weak self] in self?.drainBackend() }
    }

    private var connectionFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PgQuery", isDirectory: true)
            .appendingPathComponent("connection.txt", isDirectory: false)
    }

    private func loadSavedConnectionURL() -> String? {
        guard let data = try? Data(contentsOf: connectionFileURL),
              let value = String(data: data, encoding: .utf8),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private func saveConnectionURLToDisk(_ value: String) {
        let directory = connectionFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try Data(value.utf8).write(to: connectionFileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: connectionFileURL.path)
        } catch {
            NSLog("PgQuery: não foi possível salvar a conexão local: %@", error.localizedDescription)
        }
    }

    private func buildWindow() {
        let content = NSView()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PgQuery"
        window.contentMinSize = NSSize(width: 920, height: 560)
        window.acceptsMouseMovedEvents = true
        window.center()
        window.contentView = content
        installEditMenu()

        connectionField.placeholderString = "postgresql://usuario:senha@host:5432/banco?sslmode=require"
        connectionField.lineBreakMode = .byTruncatingMiddle
        let connectButton = PointerButton(title: "Conectar", target: self, action: #selector(connect))
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.showShortcut("↩")
        let parameterConnectButton = PointerButton(title: "Por parâmetros…", target: self, action: #selector(openSettingsFromMenu(_:)))
        parameterConnectButton.bezelStyle = .rounded
        connectionBar.addArrangedSubview(connectionField)
        connectionBar.addArrangedSubview(connectButton)
        connectionBar.addArrangedSubview(parameterConnectButton)
        [connectionField as NSView, connectButton, parameterConnectButton].forEach(applyRoundedCorners)
        connectionBar.orientation = .horizontal
        connectionBar.alignment = .centerY
        connectionBar.spacing = 10
        connectionBar.translatesAutoresizingMaskIntoConstraints = false

        connectionSummaryField.font = .systemFont(ofSize: 13, weight: .medium)
        connectionSummaryField.textColor = .systemGreen
        let settingsButton = PointerButton(title: "Configurações", target: self, action: #selector(openSettingsFromMenu(_:)))
        settingsButton.bezelStyle = .rounded
        settingsButton.showShortcut("⌘", ",")
        applyRoundedCorners(settingsButton)
        connectedBar.addArrangedSubview(connectionSummaryField)
        connectedBar.addArrangedSubview(settingsButton)
        connectedBar.orientation = .horizontal
        connectedBar.alignment = .centerY
        connectedBar.spacing = 10
        connectedBar.translatesAutoresizingMaskIntoConstraints = false
        connectedBar.isHidden = true

        let connectionArea = NSView()
        connectionArea.translatesAutoresizingMaskIntoConstraints = false
        connectionArea.addSubview(connectionBar)
        connectionArea.addSubview(connectedBar)

        let sidebarTitle = NSTextField(labelWithString: "Tabelas")
        sidebarTitle.font = .boldSystemFont(ofSize: 14)
        filterField.placeholderString = "Filtrar tabelas…"
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.delegate = self
        tableListView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("table-name")))
        tableListView.headerView = nil
        tableListView.rowHeight = 23
        tableListView.usesAlternatingRowBackgroundColors = false
        tableListView.selectionHighlightStyle = .regular
        tableListView.delegate = self
        tableListView.dataSource = self
        tableListView.target = self
        tableListView.action = #selector(tableSelected)
        let tableScroll = HoverScrollView()
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = false
        tableScroll.borderType = .bezelBorder
        applyRoundedBorder(to: tableScroll)
        applyRoundedCorners(filterField)
        tableScroll.enableHoverScrollers(horizontal: false)
        tableScroll.documentView = tableListView
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        let sidebar = NSStackView(views: [sidebarTitle, filterField, tableScroll])
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 10
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let sqlTitle = NSTextField(labelWithString: "SQL")
        sqlTitle.font = .boldSystemFont(ofSize: 14)
        queryView.string = "-- ⌘↩ executa a instrução sob o cursor · ⌘R executa tudo · ⎋ mostra sugestões\nSELECT current_database(), current_user;"
        queryView.delegate = self
        queryView.suggestWhileTyping = UserDefaults.standard.bool(forKey: "pgquery.suggest-while-typing")
        if UserDefaults.standard.object(forKey: "pgquery.editor-font-size") != nil {
            queryView.fontSize = CGFloat(UserDefaults.standard.double(forKey: "pgquery.editor-font-size"))
        }
        let sqlScroll = scrollView(for: queryView)
        sqlScrollView = sqlScroll
        applyRoundedBorder(to: sqlScroll)
        sqlScroll.hasVerticalScroller = true
        sqlScroll.autohidesScrollers = true
        queryView.minSize = NSSize(width: 0, height: 0)
        queryView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        sqlScroll.verticalRulerView = LineNumberRulerView(textView: queryView, scrollView: sqlScroll)
        sqlScroll.hasVerticalRuler = true
        sqlScroll.rulersVisible = true
        resultsTableView.headerView = NSTableHeaderView()
        resultsTableView.rowHeight = 23
        resultsTableView.usesAlternatingRowBackgroundColors = true
        resultsTableView.delegate = self
        resultsTableView.dataSource = self
        resultsTableView.allowsColumnReordering = false
        resultsTableView.allowsColumnResizing = true
        resultsTableView.allowsMultipleSelection = true
        resultsTableView.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        // Plain style: no inset gutter (and its stray line) before the first
        // column, and every column, the last included, ends with a grid line.
        if #available(macOS 11.0, *) { resultsTableView.style = .plain }
        resultsTableView.columnAutoresizingStyle = .noColumnAutoresizing
        resultsTableView.gridColor = NSColor.separatorColor
        let rowMenu = NSMenu()
        let copyJSONItem = rowMenu.addItem(withTitle: "Copiar linha(s) selecionada(s) como JSON", action: #selector(copySelectedRowsAsJSON), keyEquivalent: "")
        copyJSONItem.target = self
        resultsTableView.menu = rowMenu
        resultsTableView.translatesAutoresizingMaskIntoConstraints = false
        let resultScroll = HoverScrollView()
        resultScrollView = resultScroll
        resultScroll.hasVerticalScroller = true
        resultScroll.hasHorizontalScroller = true
        resultScroll.borderType = .bezelBorder
        applyRoundedBorder(to: resultScroll)
        resultScroll.enableHoverScrollers()
        resultScroll.documentView = resultsTableView
        resultScroll.translatesAutoresizingMaskIntoConstraints = false
        filterBar.onChange = { [weak self] in self?.reloadResults() }
        let resultFilters = filterBar.view
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 6
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        let detailScroll = NSScrollView()
        detailScrollView = detailScroll
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .bezelBorder
        applyRoundedBorder(to: detailScroll)
        detailScroll.drawsBackground = false
        detailScroll.layer?.borderWidth = 0
        let detailDocument = DetailDocumentView()
        detailDocument.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.documentView = detailDocument
        detailDocument.addSubview(detailStack)
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailPanel = NSVisualEffectView()
        detailPanel.material = .sidebar
        detailPanel.blendingMode = .withinWindow
        detailPanel.state = .active
        detailPanel.translatesAutoresizingMaskIntoConstraints = false
        detailPanel.wantsLayer = true
        detailPanel.layer?.cornerRadius = 8
        detailPanel.layer?.masksToBounds = true
        detailPanel.layer?.borderWidth = 1
        detailPanel.layer?.borderColor = NSColor.separatorColor.cgColor
        let drawerTitle = NSTextField(labelWithString: "Detalhes da linha")
        drawerTitle.font = .boldSystemFont(ofSize: 14)
        let closeDrawerButton = PointerButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Fechar detalhes")!, target: self, action: #selector(closeRowDetails(_:)))
        closeDrawerButton.isBordered = false
        closeDrawerButton.imagePosition = .imageOnly
        detailBackButton.target = self
        detailBackButton.action = #selector(navigateBack(_:))
        detailBackButton.bezelStyle = .rounded
        detailBackButton.controlSize = .small
        detailBackButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Voltar")
        detailBackButton.imagePosition = .imageLeading
        detailBackButton.toolTip = "Voltar para o resultado anterior"
        detailBackButton.isHidden = true
        let drawerLeading = NSStackView(views: [detailBackButton, drawerTitle])
        drawerLeading.orientation = .horizontal
        drawerLeading.alignment = .centerY
        drawerLeading.spacing = 8
        let drawerHeader = NSStackView(views: [drawerLeading, closeDrawerButton])
        drawerHeader.orientation = .horizontal
        drawerHeader.alignment = .centerY
        drawerHeader.distribution = .equalSpacing
        drawerHeader.translatesAutoresizingMaskIntoConstraints = false
        detailPanel.addSubview(drawerHeader)
        detailPanel.addSubview(detailScroll)
        detailPanel.isHidden = true
        let resultsArea = NSStackView(views: [resultScroll])
        resultsArea.orientation = .horizontal
        resultsArea.alignment = .top
        resultsArea.spacing = 8
        resultsArea.translatesAutoresizingMaskIntoConstraints = false
        let runButton = PointerButton(title: "Executar SQL", target: self, action: #selector(runQuery))
        sqlRunButton = runButton
        runButton.bezelStyle = .rounded
        runButton.toolTip = "Executar SQL (⌘R)\nRoda todo o conteúdo do editor, com todas as instruções.\nSe houver texto selecionado, roda só a seleção."
        runButton.showShortcut("⌘", "R")
        let runStatementButton = PointerButton(title: "Executar instrução", target: self, action: #selector(runCurrentStatement))
        runStatementButton.bezelStyle = .rounded
        // Primary action: running the statement under the caret.
        runStatementButton.bezelColor = .controlAccentColor
        runStatementButton.toolTip = "Executar instrução (⌘↩)\nRoda só a instrução onde está o cursor; as instruções são separadas por ponto e vírgula (;).\nÚtil para manter várias consultas no editor e rodar uma de cada vez.\nSe houver texto selecionado, roda só a seleção."
        runStatementButton.showShortcut("⌘", "↩", onAccent: true)
        sqlRunStatementButton = runStatementButton
        let clearButton = PointerButton(title: "Limpar", target: self, action: #selector(clearResults))
        clearResultsButton = clearButton
        clearButton.bezelStyle = .rounded
        clearButton.showShortcut("⌘", "K")
        let copyButton = PointerButton(title: "Copiar resultado", target: self, action: #selector(copyResults))
        copyResultsButton = copyButton
        copyButton.bezelStyle = .rounded
        copyButton.showShortcut("⇧", "⌘", "C")
        clearButton.isHidden = true
        copyButton.isHidden = true
        [runButton, runStatementButton, clearButton, copyButton].forEach(applyRoundedCorners)
        resultNote.textColor = .secondaryLabelColor
        resultNote.font = .systemFont(ofSize: 11)
        resultNote.lineBreakMode = .byTruncatingTail
        let controls = NSStackView(views: [runStatementButton, runButton, resultNote, copyButton, clearButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        let resultsTitle = NSTextField(labelWithString: "Resultados")
        resultsTitle.font = .boldSystemFont(ofSize: 14)

        let toggleSQLEditorButton = PointerButton(title: "Ocultar editor SQL", target: self, action: #selector(toggleSQLEditor))
        toggleSQLEditorButton.bezelStyle = .rounded
        applyRoundedCorners(toggleSQLEditorButton)
        let sqlHeading = NSStackView(views: [sqlTitle, toggleSQLEditorButton])
        sqlHeading.orientation = .horizontal
        sqlHeading.alignment = .centerY
        sqlHeading.spacing = 10
        let main = NSStackView(views: [sqlHeading, sqlScroll, controls, resultsTitle, resultFilters, resultsArea])
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 10
        main.translatesAutoresizingMaskIntoConstraints = false

        let lower = NSStackView(views: [sidebar, main])
        lower.orientation = .horizontal
        lower.alignment = .top
        lower.spacing = 12
        lower.translatesAutoresizingMaskIntoConstraints = false
        metricsField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        metricsField.textColor = .secondaryLabelColor
        tlsWarningField.font = .systemFont(ofSize: 10, weight: .medium)
        tlsWarningField.textColor = .secondaryLabelColor
        tlsWarningField.alignment = .right
        tlsWarningField.lineBreakMode = .byTruncatingTail
        tlsWarningField.toolTip = "TLS está ativo, mas o certificado do servidor não foi validado."
        tlsWarningField.isHidden = true
        let footerSpacer = NSView()
        let footer = NSStackView(views: [metricsField, footerSpacer, tlsWarningField])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false
        let root = NSStackView(views: [connectionArea, lower, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        appShell.orientation = .horizontal
        appShell.alignment = .top
        appShell.spacing = 12
        appShell.translatesAutoresizingMaskIntoConstraints = false
        appShell.addArrangedSubview(root)
        appShell.addArrangedSubview(detailPanel)
        content.addSubview(appShell)

        NSLayoutConstraint.activate([
            appShell.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            appShell.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            appShell.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            appShell.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: appShell.topAnchor),
            root.bottomAnchor.constraint(equalTo: appShell.bottomAnchor),
            detailPanel.topAnchor.constraint(equalTo: appShell.topAnchor),
            detailPanel.bottomAnchor.constraint(equalTo: appShell.bottomAnchor),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor),
            connectionArea.widthAnchor.constraint(equalTo: root.widthAnchor),
            connectionArea.heightAnchor.constraint(equalToConstant: 36),
            connectionBar.leadingAnchor.constraint(equalTo: connectionArea.leadingAnchor),
            connectionBar.trailingAnchor.constraint(equalTo: connectionArea.trailingAnchor),
            connectionBar.topAnchor.constraint(equalTo: connectionArea.topAnchor),
            connectionBar.bottomAnchor.constraint(equalTo: connectionArea.bottomAnchor),
            connectedBar.leadingAnchor.constraint(equalTo: connectionArea.leadingAnchor),
            connectedBar.trailingAnchor.constraint(equalTo: connectionArea.trailingAnchor),
            connectedBar.topAnchor.constraint(equalTo: connectionArea.topAnchor),
            connectedBar.bottomAnchor.constraint(equalTo: connectionArea.bottomAnchor),
            lower.widthAnchor.constraint(equalTo: root.widthAnchor),
            lower.heightAnchor.constraint(equalTo: root.heightAnchor, constant: -78),
            sidebar.widthAnchor.constraint(equalToConstant: 230),
            sidebar.heightAnchor.constraint(equalTo: lower.heightAnchor),
            main.widthAnchor.constraint(equalTo: lower.widthAnchor, constant: -242),
            main.heightAnchor.constraint(equalTo: lower.heightAnchor),
            sqlHeading.widthAnchor.constraint(equalTo: main.widthAnchor),
            sqlScroll.widthAnchor.constraint(equalTo: main.widthAnchor),
            resultsArea.widthAnchor.constraint(equalTo: main.widthAnchor),
            detailDocument.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor),
            detailStack.leadingAnchor.constraint(equalTo: detailDocument.leadingAnchor, constant: 4),
            detailStack.trailingAnchor.constraint(equalTo: detailDocument.trailingAnchor, constant: -4),
            detailStack.topAnchor.constraint(equalTo: detailDocument.topAnchor, constant: 4),
            detailStack.bottomAnchor.constraint(equalTo: detailDocument.bottomAnchor, constant: -12),
            drawerHeader.leadingAnchor.constraint(equalTo: detailPanel.leadingAnchor, constant: 20),
            drawerHeader.trailingAnchor.constraint(equalTo: detailPanel.trailingAnchor, constant: -20),
            drawerHeader.topAnchor.constraint(equalTo: detailPanel.topAnchor, constant: 18),
            detailScroll.leadingAnchor.constraint(equalTo: detailPanel.leadingAnchor, constant: 16),
            detailScroll.trailingAnchor.constraint(equalTo: detailPanel.trailingAnchor, constant: -16),
            detailScroll.topAnchor.constraint(equalTo: drawerHeader.bottomAnchor, constant: 14),
            detailScroll.bottomAnchor.constraint(equalTo: detailPanel.bottomAnchor, constant: -16),
            resultFilters.widthAnchor.constraint(equalTo: main.widthAnchor),
            controls.widthAnchor.constraint(equalTo: main.widthAnchor),
            resultScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 170),
            connectionField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            filterField.widthAnchor.constraint(equalTo: sidebar.widthAnchor),
            tableScroll.widthAnchor.constraint(equalTo: sidebar.widthAnchor),
            tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
        sqlMinimumHeightConstraint = sqlScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 170)
        sqlResultsEqualHeightConstraint = sqlScroll.heightAnchor.constraint(equalTo: resultScroll.heightAnchor)
        sqlMinimumHeightConstraint.isActive = true
        sqlResultsEqualHeightConstraint.isActive = true
        detailPanelWidthConstraint = detailPanel.widthAnchor.constraint(equalToConstant: 340)
        rootFullWidthConstraint = root.widthAnchor.constraint(equalTo: appShell.widthAnchor)
        rootDrawerWidthConstraint = root.widthAnchor.constraint(equalTo: appShell.widthAnchor, constant: -352)
        rootFullWidthConstraint.isActive = true

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(queryView)
    }

    private func applyRoundedCorners(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.masksToBounds = true
    }

    private func applyRoundedBorder(to scrollView: NSScrollView) {
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        applyRoundedCorners(scrollView)
        scrollView.layer?.borderWidth = 1
        scrollView.layer?.borderColor = NSColor.separatorColor.cgColor
    }

    private func scrollView(for textView: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    private func installEditMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        appItem.title = "PgQuery"
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Configurações…", action: #selector(openSettingsFromMenu(_:)), keyEquivalent: ",")
        settingsItem.target = self
        let updatesItem = NSMenuItem(title: "Verificar atualizações", action: nil, keyEquivalent: "")
        updatesItem.image = nil
        updateMenuItem = updatesItem
        appMenu.addItem(updatesItem)
        appMenu.addItem(settingsItem)
        appMenu.addItem(withTitle: "Sair do PgQuery", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let editItem = NSMenuItem()
        editItem.title = "Editar"
        let editMenu = NSMenu(title: "Editar")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        for (title, selector, key) in [
            ("Desfazer", "undo:", "z"), ("Refazer", "redo:", "Z"), ("Recortar", "cut:", "x"),
            ("Copiar", "copy:", "c"), ("Colar", "paste:", "v"), ("Selecionar Tudo", "selectAll:", "a"),
        ] {
            let item = NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            editMenu.addItem(item)
        }
        editMenu.addItem(.separator())
        // NSTextFinder actions: show find, next, previous, use selection, replace.
        for (title, key, modifiers, tag) in [
            ("Buscar…", "f", NSEvent.ModifierFlags.command, 1), ("Buscar e substituir…", "f", [.command, .option], 12),
            ("Buscar próxima", "g", .command, 2), ("Buscar anterior", "g", [.command, .shift], 3),
            ("Usar seleção para buscar", "e", .command, 7),
        ] as [(String, String, NSEvent.ModifierFlags, Int)] {
            let item = NSMenuItem(title: title, action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = tag
            editMenu.addItem(item)
        }

        let sqlItem = NSMenuItem()
        sqlItem.title = "SQL"
        let sqlMenu = NSMenu(title: "SQL")
        sqlItem.submenu = sqlMenu
        menu.addItem(sqlItem)
        func add(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            sqlMenu.addItem(item)
            return item
        }
        _ = add("Executar instrução atual", #selector(runCurrentStatement), "\r", target: self)
        _ = add("Executar tudo (ou seleção)", #selector(runQuery), "r", target: self)
        _ = add("Copiar resultado", #selector(copyResults), "c", [.command, .shift], target: self)
        _ = add("Limpar resultado", #selector(clearResults), "k", target: self)
        sqlMenu.addItem(.separator())
        // ⎋ / ⌃Space are handled by the editor itself: a menu shortcut on ⎋
        // would steal the key that closes the suggestion list.
        _ = add("Mostrar sugestões (⎋ ou ⌃Espaço)", #selector(SQLTextView.showCompletions(_:)), "", [])
        let suggest = add("Sugerir colunas enquanto digita", #selector(toggleSuggestWhileTyping(_:)), "", target: self)
        suggest.state = UserDefaults.standard.bool(forKey: "pgquery.suggest-while-typing") ? .on : .off
        suggestWhileTypingItem = suggest
        sqlMenu.addItem(.separator())
        _ = add("Comentar/descomentar linhas", #selector(SQLTextView.toggleLineComment(_:)), "/")
        _ = add("Duplicar linha", #selector(SQLTextView.duplicateLine(_:)), "d")
        _ = add("Indentar", #selector(indentSelection(_:)), "]", target: self)
        _ = add("Desindentar", #selector(outdentSelection(_:)), "[", target: self)
        sqlMenu.addItem(.separator())
        _ = add("Aumentar fonte", #selector(changeEditorFont(_:)), "+", target: self).tag = 1
        _ = add("Diminuir fonte", #selector(changeEditorFont(_:)), "-", target: self).tag = -1
        _ = add("Tamanho padrão", #selector(changeEditorFont(_:)), "0", target: self).tag = 0
        NSApp.mainMenu = menu
    }

    private func configureUpdater() {
        let delegate = PgQueryUpdaterDelegate()
        delegate.updateAvailabilityChanged = { [weak self] available in
            guard let self, let item = self.updateMenuItem else { return }
            if available {
                let dot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Atualização disponível")
                dot?.isTemplate = false
                item.image = dot?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemBlue]))
            } else {
                item.image = nil
            }
        }
        updaterDelegate = delegate
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        updateMenuItem?.target = updaterController
        updateMenuItem?.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
    }

    @objc private func toggleSQLEditor(_ sender: NSButton) {
        sqlEditorVisible.toggle()
        sqlScrollView.isHidden = !sqlEditorVisible
        sqlRunButton.isHidden = !sqlEditorVisible
        sqlRunStatementButton.isHidden = !sqlEditorVisible
        sender.title = sqlEditorVisible ? "Ocultar editor SQL" : "Mostrar editor SQL"
        sqlMinimumHeightConstraint.isActive = sqlEditorVisible
        sqlResultsEqualHeightConstraint.isActive = sqlEditorVisible
    }

    @objc private func openSettingsFromMenu(_ sender: Any?) {
        openSettingsWindow()
    }

    private func openSettingsWindow() {
        guard window.attachedSheet == nil else { return }
        if settingsWindow == nil {
            settingsWindow = buildSettingsWindow()
            settingsWindow?.isReleasedWhenClosed = false
        }
        secureURLField.stringValue = connectionURL
        visibleURLField.stringValue = connectionURL
        populateConnectionParameters(from: connectionURL)
        connectionModePicker.selectedSegment = 0
        connectionModeChanged(nil)
        revealURLButton.state = .off
        toggleURLVisibility(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let settingsWindow {
            window.beginSheet(settingsWindow)
            settingsWindow.makeFirstResponder(secureURLField)
        }
    }

    private func buildSettingsWindow() -> NSWindow {
        let settings = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        settings.title = "Configurações de conexão"

        let title = NSTextField(labelWithString: "URL do banco")
        title.font = .boldSystemFont(ofSize: 13)
        secureURLField.placeholderString = "postgresql://usuario:senha@host:5432/banco"
        visibleURLField.placeholderString = secureURLField.placeholderString
        visibleURLField.lineBreakMode = .byTruncatingMiddle
        visibleURLField.isHidden = true
        revealURLButton.target = self
        revealURLButton.action = #selector(toggleURLVisibility(_:))

        connectionModePicker.selectedSegment = 0
        connectionModePicker.target = self
        connectionModePicker.action = #selector(connectionModeChanged(_:))
        connectionURLStack = NSStackView(views: [title, secureURLField, visibleURLField, revealURLButton])
        connectionURLStack.orientation = .vertical
        connectionURLStack.alignment = .leading
        connectionURLStack.spacing = 8
        connectionURLStack.translatesAutoresizingMaskIntoConstraints = false

        hostField.placeholderString = "db.exemplo.supabase.co"
        portField.placeholderString = "5432"
        portField.stringValue = "5432"
        databaseField.placeholderString = "postgres"
        usernameField.placeholderString = "Usuário"
        passwordField.placeholderString = "Senha"
        sslModeField.addItems(withTitles: ["require", "prefer", "verify-ca", "verify-full", "disable"])
        for (label, field) in [("Host", hostField), ("Porta", portField), ("Banco", databaseField), ("Usuário", usernameField), ("Senha", passwordField)] {
            let fieldLabel = NSTextField(labelWithString: label)
            fieldLabel.widthAnchor.constraint(equalToConstant: 82).isActive = true
            let row = NSStackView(views: [fieldLabel, field])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            connectionParameterStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: connectionParameterStack.widthAnchor).isActive = true
        }
        let sslLabel = NSTextField(labelWithString: "SSL")
        sslLabel.widthAnchor.constraint(equalToConstant: 82).isActive = true
        let sslRow = NSStackView(views: [sslLabel, sslModeField])
        sslRow.orientation = .horizontal
        sslRow.alignment = .centerY
        sslRow.spacing = 10
        connectionParameterStack.addArrangedSubview(sslRow)
        connectionParameterStack.orientation = .vertical
        connectionParameterStack.alignment = .leading
        connectionParameterStack.spacing = 8
        connectionParameterStack.translatesAutoresizingMaskIntoConstraints = false
        connectionParameterStack.isHidden = true

        let cancelButton = PointerButton(title: "Cancelar", target: self, action: #selector(closeSettings(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.showShortcut("⎋")
        let saveButton = PointerButton(title: "Salvar e reconectar", target: self, action: #selector(saveConnectionSettings(_:)))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.showShortcut("↩")
        let buttons = NSStackView(views: [cancelButton, saveButton])
        [secureURLField as NSView, visibleURLField, hostField, portField, databaseField, usernameField, passwordField, sslModeField, cancelButton, saveButton].forEach(applyRoundedCorners)
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView(views: [connectionModePicker, connectionURLStack, connectionParameterStack, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        settings.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: settings.contentView!.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: settings.contentView!.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: settings.contentView!.topAnchor, constant: 18),
            root.bottomAnchor.constraint(equalTo: settings.contentView!.bottomAnchor, constant: -18),
            connectionModePicker.widthAnchor.constraint(equalTo: root.widthAnchor),
            connectionURLStack.widthAnchor.constraint(equalTo: root.widthAnchor),
            connectionParameterStack.widthAnchor.constraint(equalTo: root.widthAnchor),
            secureURLField.widthAnchor.constraint(equalTo: root.widthAnchor),
            visibleURLField.widthAnchor.constraint(equalTo: root.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: root.widthAnchor),
            hostField.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -100),
            portField.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -100),
            databaseField.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -100),
            usernameField.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -100),
            passwordField.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -100),
            sslModeField.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -100),
        ])
        return settings
    }

    @objc private func connectionModeChanged(_ sender: Any?) {
        let usingParameters = connectionModePicker.selectedSegment == 1
        connectionURLStack.isHidden = usingParameters
        connectionParameterStack.isHidden = !usingParameters
    }

    private func populateConnectionParameters(from value: String) {
        guard let components = URLComponents(string: value), components.scheme?.hasPrefix("postgres") == true else { return }
        hostField.stringValue = components.host ?? ""
        portField.stringValue = String(components.port ?? 5432)
        databaseField.stringValue = String(components.path.dropFirst())
        usernameField.stringValue = components.user?.removingPercentEncoding ?? components.user ?? ""
        passwordField.stringValue = components.password?.removingPercentEncoding ?? components.password ?? ""
        if let mode = components.queryItems?.first(where: { $0.name == "sslmode" })?.value,
           let index = sslModeField.itemTitles.firstIndex(of: mode) { sslModeField.selectItem(at: index) }
    }

    private func connectionURLFromParameters() -> String? {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let database = databaseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !database.isEmpty, !username.isEmpty,
              let port = Int(portField.stringValue), (1...65535).contains(port) else { return nil }
        var components = URLComponents()
        components.scheme = "postgresql"
        components.host = host
        components.port = port
        components.user = username
        components.password = passwordField.stringValue
        components.path = "/" + database
        components.queryItems = [URLQueryItem(name: "sslmode", value: sslModeField.titleOfSelectedItem ?? "require")]
        return components.string
    }

    @objc private func toggleURLVisibility(_ sender: Any?) {
        if revealURLButton.state == .on {
            visibleURLField.stringValue = secureURLField.stringValue
            secureURLField.isHidden = true
            visibleURLField.isHidden = false
            settingsWindow?.makeFirstResponder(visibleURLField)
        } else {
            secureURLField.stringValue = visibleURLField.stringValue
            visibleURLField.isHidden = true
            secureURLField.isHidden = false
            settingsWindow?.makeFirstResponder(secureURLField)
        }
    }

    @objc private func closeSettings(_ sender: Any?) {
        if let settingsWindow { window.endSheet(settingsWindow) }
    }

    @objc private func saveConnectionSettings(_ sender: Any?) {
        let value: String
        if connectionModePicker.selectedSegment == 1 {
            guard let parameterURL = connectionURLFromParameters() else {
                resultNote.stringValue = "Preencha host, porta, banco e usuário"
                return
            }
            value = parameterURL
        } else {
            value = revealURLButton.state == .on ? visibleURLField.stringValue : secureURLField.stringValue
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        connectionURL = value
        connectionField.stringValue = value
        if let settingsWindow { window.endSheet(settingsWindow) }
        connect()
    }

    @objc private func connect() {
        guard !connectionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        connectionURL = connectionField.stringValue
        setConnected(false)
        connectionField.stringValue.withCString { pg_connect($0) }
    }

    private func setConnected(_ connected: Bool) {
        if connected {
            hasConnectedOnce = true
            connectionSummaryField.isHidden = true
            connectionSummaryField.textColor = .systemGreen
            connectionBar.isHidden = true
            connectedBar.isHidden = false
        } else if hasConnectedOnce {
            connectionSummaryField.isHidden = false
            connectionSummaryField.stringValue = "Desconectado · URL oculta"
            connectionSummaryField.textColor = .secondaryLabelColor
            connectionBar.isHidden = true
            connectedBar.isHidden = false
        } else {
            connectionBar.isHidden = false
            connectedBar.isHidden = true
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSTextField) === filterField { filterChanged() }
    }

    @objc private func filterChanged() {
        cachedFilteredTables = nil
        tableListView.reloadData()
    }

    @objc private func tableSelected() {
        let visible = filteredTables
        let index = tableListView.selectedRow
        guard index >= 0, index < visible.count else { return }
        resetResults()
        filterBar.removeAll()  // another table: its filters don't apply
        previewTable = visible[index]
        visible[index].withCString { pg_select_table($0) }
    }

    /// ⌘R / button: runs the selection, or the whole editor.
    @objc private func runQuery() {
        let source = queryView.string as NSString
        let selection = queryView.selectedRange()
        let range = selection.length > 0 ? SQLLexer.trim(selection, in: source) : NSRange(location: 0, length: source.length)
        execute(range)
    }

    /// ⌘↩: runs the selection, or only the statement under the caret.
    @objc private func runCurrentStatement() {
        guard let range = queryView.executableRange() else { NSSound.beep(); return }
        queryView.flash(range)
        execute(range)
    }

    private func execute(_ range: NSRange) {
        let source = queryView.string as NSString
        guard range.length > 0, NSMaxRange(range) <= source.length else { return }
        let sql = source.substring(with: range)
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        queryView.hideCompletions()
        resetResults()
        resultNote.stringValue = "Executando…"
        resultNote.toolTip = nil
        lastExecutedSQL = sql
        lastExecutedOffset = range.location
        sql.withCString { pg_query($0) }
    }

    @objc private func toggleSuggestWhileTyping(_ sender: NSMenuItem) {
        queryView.suggestWhileTyping.toggle()
        sender.state = queryView.suggestWhileTyping ? .on : .off
        UserDefaults.standard.set(queryView.suggestWhileTyping, forKey: "pgquery.suggest-while-typing")
    }

    @objc private func indentSelection(_ sender: Any?) { queryView.shiftSelectedLines(outdent: false) }
    @objc private func outdentSelection(_ sender: Any?) { queryView.shiftSelectedLines(outdent: true) }

    @objc private func changeEditorFont(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: queryView.fontSize += 1
        case -1: queryView.fontSize -= 1
        default: queryView.fontSize = 13
        }
        UserDefaults.standard.set(Double(queryView.fontSize), forKey: "pgquery.editor-font-size")
    }

    /// Maps PostgreSQL's 1-based character position in the executed SQL to
    /// the editor and underlines it.
    private func highlightErrorPosition(in message: String) {
        guard let match = message.range(of: #"Posição na consulta: (\d+)"#, options: .regularExpression),
              let position = Int(message[match].split(separator: " ").last ?? ""), position > 0 else { return }
        let scalars = lastExecutedSQL.unicodeScalars
        guard let index = scalars.index(scalars.startIndex, offsetBy: position - 1, limitedBy: scalars.endIndex) else { return }
        let offset = lastExecutedSQL.utf16.distance(from: lastExecutedSQL.utf16.startIndex, to: index.samePosition(in: lastExecutedSQL.utf16) ?? lastExecutedSQL.utf16.endIndex)
        window.makeFirstResponder(queryView)
        queryView.markError(at: lastExecutedOffset + offset)
    }

    /// "Limpar" button / ⌘K: also drops the filters.
    @objc private func clearResults() {
        resetResults()
        filterBar.removeAll()
        reloadResults()
    }

    /// Clears the grid before a new query; filters stay so a re-run keeps them.
    private func resetResults() {
        resultHeaders = []
        resultRows = []
        resultTypes = []
        resultForeignKeys = []
        navigationStack.removeAll()
        openDetailsOnNextResult = false
        configureResultColumns()
        reloadResults()
        resultSortColumn = nil
        closeRowDetails()
        resultNote.stringValue = ""
        hasExecutedQuery = false
        updateResultActionVisibility()
    }

    private func updateResultActionVisibility() {
        copyResultsButton?.isHidden = !hasExecutedQuery
        clearResultsButton?.isHidden = !hasExecutedQuery
    }

    @objc private func copyResults() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if resultScrollView.documentView === planView {
            pasteboard.setString(planView.planText, forType: .string)
            resultNote.stringValue = "Plano copiado"
            return
        }
        let lines = ([resultHeaders] + resultRows).map { row in
            row.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t")
        }
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
        resultNote.stringValue = "Resultado copiado"
    }

    @objc private func slowTimer(_ timer: Timer) {
        drainBackend()
        // No point measuring while the window is hidden or minimized.
        if window.occlusionState.contains(.visible) { updateResourceStats() }
    }

    private func updateResourceStats() {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let cpuNs = usage.ri_user_time + usage.ri_system_time
        let cpuPercent: Double
        if let lastCpuNs, let lastSampleNs, now > lastSampleNs {
            cpuPercent = Double(cpuNs >= lastCpuNs ? cpuNs - lastCpuNs : 0) / Double(now - lastSampleNs) * 100
        } else {
            cpuPercent = 0
        }
        self.lastCpuNs = cpuNs
        self.lastSampleNs = now
        let footprintMiB = Double(usage.ri_phys_footprint) / 1_048_576
        metricsField.stringValue = String(format: "Este app · CPU %.1f%% · Memória %.0f MiB", cpuPercent, footprintMiB)
    }

    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === queryView else { return }
        // Persist the editor contents shortly after typing stops.
        saveSQLWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(self.queryView.string, forKey: "pgquery.last-sql")
        }
        saveSQLWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func applicationWillTerminate(_ notification: Notification) {
        UserDefaults.standard.set(queryView.string, forKey: "pgquery.last-sql")
    }

    /// Cached: the sidebar asks for it once per row and per redraw, and a
    /// database can have thousands of tables.
    private var cachedFilteredTables: [String]?

    private var filteredTables: [String] {
        if let cachedFilteredTables { return cachedFilteredTables }
        let needle = filterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = needle.isEmpty ? tables : tables.filter { displayName(for: $0).localizedCaseInsensitiveContains(needle) }
        cachedFilteredTables = result
        return result
    }

    private func displayName(for table: String) -> String {
        table.hasPrefix("public.") ? String(table.dropFirst("public.".count)) : table
    }

    /// Visible rows after filters and sorting; cached because the grid asks
    /// for it once per cell. Invalidated by `reloadResults()`.
    private var cachedResultIndexes: [Int]?
    private var resultScrollView: HoverScrollView!
    private let planView = PlanView()

    private var filteredResultIndexes: [Int] {
        if let cachedResultIndexes { return cachedResultIndexes }
        let indexes = computeResultIndexes()
        cachedResultIndexes = indexes
        return indexes
    }

    private func computeResultIndexes() -> [Int] {
        var indexes = filterBar.filters.apply(headers: resultHeaders, rows: resultRows) { [valueFormatter, resultTypes] raw, column in
            valueFormatter.display(raw, type: column < resultTypes.count ? resultTypes[column] : nil)
        }
        if let column = resultSortColumn {
            indexes.sort { left, right in
                guard column < resultRows[left].count, column < resultRows[right].count else { return left < right }
                let comparison = resultRows[left][column].localizedStandardCompare(resultRows[right][column])
                return resultSortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
        }
        return indexes
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === tableListView ? filteredTables.count : filteredResultIndexes.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView === resultsTableView ? ResultsRowView() : nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === tableListView {
            let visible = filteredTables
            let cell = (tableView.makeView(withIdentifier: TableListCell.identifier, owner: self) as? TableListCell) ?? TableListCell()
            guard row < visible.count else { return cell }
            let estimate = tableEstimates[visible[row]]
            cell.configure(name: displayName(for: visible[row]), count: estimate.map { RowEstimate.short($0) } ?? "")
            cell.toolTip = estimate.map { visible[row] + "\n" + RowEstimate.long($0) }
            return cell
        }
        let identifier = NSUserInterfaceItemIdentifier(tableView === tableListView ? "table-cell" : "result-cell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? NSTableCellView()
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true
            label.maximumNumberOfLines = 1
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.identifier = identifier
        if tableView === tableListView {
            let visible = filteredTables
            guard row < visible.count else { return cell }
            cell.textField?.font = .systemFont(ofSize: 12)
            cell.textField?.stringValue = displayName(for: visible[row])
        } else {
            let indexes = filteredResultIndexes
            guard row < indexes.count, let tableColumn,
                  let columnIndex = tableView.tableColumns.firstIndex(of: tableColumn),
                  columnIndex < resultRows[indexes[row]].count else { return cell }
            let raw = resultRows[indexes[row]][columnIndex]
            let type = columnIndex < resultTypes.count ? resultTypes[columnIndex] : nil
            cell.textField?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            cell.textField?.stringValue = flattenedCellText(valueFormatter.display(raw, type: type))
            // Cells are reused, so always reset the color.
            cell.textField?.textColor = raw == "NULL" ? .tertiaryLabelColor
                : ValueFormatter.kind(of: type) == .boolean ? (raw == "t" ? .systemGreen : .secondaryLabelColor)
                : .labelColor
        }
        return cell
    }

    private func configureResultColumns() {
        for column in resultsTableView.tableColumns {
            resultsTableView.removeTableColumn(column)
        }
        for (index, header) in resultHeaders.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result-\(index)"))
            column.title = header
            column.width = max(120, min(220, CGFloat(header.count * 9 + 24)))
            column.sortDescriptorPrototype = NSSortDescriptor(key: "column-\(index)", ascending: true)
            resultsTableView.addTableColumn(column)
        }
        filterBar.setHeaders(resultHeaders)
        resultSortColumn = nil
    }

    private func reloadResults() {
        cachedResultIndexes = nil
        // EXPLAIN output reads better as plain text than as a one-column grid.
        if PlanView.isPlan(headers: resultHeaders, rows: resultRows) {
            planView.show(rows: resultRows)
            if resultScrollView.documentView !== planView { resultScrollView.documentView = planView }
        } else if resultScrollView.documentView !== resultsTableView {
            resultScrollView.documentView = resultsTableView
        }
        resultsTableView.reloadData()
        filterBar.updateSummary(visible: filteredResultIndexes.count, total: resultRows.count)
    }

    private func flattenedCellText(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\u{2028}", with: " ")
            .replacingOccurrences(of: "\u{2029}", with: " ")
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard tableView === resultsTableView, let descriptor = tableView.sortDescriptors.first,
              let raw = descriptor.key, let index = Int(raw.replacingOccurrences(of: "column-", with: "")) else { return }
        resultSortColumn = index
        resultSortAscending = descriptor.ascending
        reloadResults()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView, table === resultsTableView else { return }
        guard table.selectedRow >= 0 else { closeRowDetails(); return }
        let indexes = filteredResultIndexes
        guard table.selectedRow < indexes.count else { return }
        showRowDetails(at: indexes[table.selectedRow])
    }

    private func showRowDetails(at row: Int) {
        guard row < resultRows.count else { return }
        for view in detailStack.arrangedSubviews { detailStack.removeArrangedSubview(view); view.removeFromSuperview() }
        detailBackButton.isHidden = navigationStack.isEmpty
        for (index, header) in resultHeaders.enumerated() {
            let raw = index < resultRows[row].count ? resultRows[row][index] : "NULL"
            let type = index < resultTypes.count ? resultTypes[index] : nil
            let foreignKey = index < resultForeignKeys.count ? resultForeignKeys[index] : []

            let name = NSTextField(labelWithString: header)
            name.font = .systemFont(ofSize: 11, weight: .semibold)
            name.textColor = .secondaryLabelColor
            let nameRow = NSStackView(views: [name])
            nameRow.orientation = .horizontal
            nameRow.spacing = 6
            if let type, !type.isEmpty {
                let typeLabel = NSTextField(labelWithString: type)
                typeLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
                typeLabel.textColor = .tertiaryLabelColor
                nameRow.addArrangedSubview(typeLabel)
            }

            let formatted = valueFormatter.detail(raw, type: type)
            let value = NSTextField(wrappingLabelWithString: formatted.value)
            value.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            value.textColor = raw == "NULL" ? .tertiaryLabelColor : .labelColor
            value.maximumNumberOfLines = 0
            value.lineBreakMode = .byWordWrapping
            value.isSelectable = true
            value.preferredMaxLayoutWidth = 270
            value.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let valueRow = NSStackView(views: [value])
            valueRow.orientation = .horizontal
            valueRow.alignment = .top
            valueRow.spacing = 6
            valueRow.translatesAutoresizingMaskIntoConstraints = false
            if foreignKey.count == 3, raw != "NULL" {
                // Jump to the referenced row in the other table.
                let jump = PointerButton(image: NSImage(systemSymbolName: "arrow.right.circle.fill", accessibilityDescription: "Abrir linha referenciada")!, target: self, action: #selector(followForeignKey(_:)))
                jump.isBordered = false
                jump.imagePosition = .imageOnly
                jump.contentTintColor = .controlAccentColor
                jump.toolTip = "Abrir \(displayName(for: foreignKey[0] + "." + foreignKey[1])) onde \(foreignKey[2]) = \(raw)"
                jump.identifier = NSUserInterfaceItemIdentifier("fk-\(index)")
                jump.tag = row
                jump.setContentHuggingPriority(.required, for: .horizontal)
                valueRow.addArrangedSubview(jump)
                name.stringValue = header + "  →  " + displayName(for: foreignKey[0] + "." + foreignKey[1])
            }
            detailStack.addArrangedSubview(nameRow)
            detailStack.addArrangedSubview(valueRow)
            valueRow.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
            if let original = formatted.original {
                let originalLabel = NSTextField(labelWithString: original)
                originalLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
                originalLabel.textColor = .tertiaryLabelColor
                originalLabel.isSelectable = true
                detailStack.addArrangedSubview(originalLabel)
                detailStack.setCustomSpacing(4, after: valueRow)
            }
            let separator = NSBox()
            separator.boxType = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            detailStack.addArrangedSubview(separator)
            separator.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
            detailStack.setCustomSpacing(12, after: separator)
        }
        detailPanel.isHidden = false
        rootFullWidthConstraint.isActive = false
        detailPanelWidthConstraint.isActive = true
        rootDrawerWidthConstraint.isActive = true
        detailPanel.layoutSubtreeIfNeeded()
        detailScrollView.contentView.scroll(to: .zero)
        detailScrollView.reflectScrolledClipView(detailScrollView.contentView)
    }

    @objc private func followForeignKey(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("fk-"), let column = Int(raw.dropFirst(3)),
              column < resultForeignKeys.count, resultForeignKeys[column].count == 3,
              sender.tag < resultRows.count, column < resultRows[sender.tag].count else { return }
        let target = resultForeignKeys[column]
        let value = resultRows[sender.tag][column]
        // Each snapshot can hold up to 2 MB of rows, so keep the history short.
        if navigationStack.count >= 20 { navigationStack.removeFirst() }
        navigationStack.append(ResultSnapshot(headers: resultHeaders, types: resultTypes, foreignKeys: resultForeignKeys,
                                              rows: resultRows, note: resultNote.stringValue, selectedRow: sender.tag))
        let quote = { (identifier: String) in "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let literal = "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        let sql = "SELECT * FROM \(quote(target[0])).\(quote(target[1])) WHERE \(quote(target[2])) = \(literal) LIMIT 500"
        openDetailsOnNextResult = true
        lastExecutedSQL = ""  // errors here do not point into the editor
        resultNote.stringValue = "Abrindo \(displayName(for: target[0] + "." + target[1])) onde \(target[2]) = \(value)…"
        resultNote.toolTip = sql
        sql.withCString { pg_query($0) }
    }

    @objc private func navigateBack(_ sender: Any?) {
        guard let snapshot = navigationStack.popLast() else { return }
        openDetailsOnNextResult = false
        apply(snapshot)
        if let row = snapshot.selectedRow, let visible = filteredResultIndexes.firstIndex(of: row) {
            resultsTableView.selectRowIndexes(IndexSet(integer: visible), byExtendingSelection: false)
            resultsTableView.scrollRowToVisible(visible)
            showRowDetails(at: row)
        }
    }

    private func apply(_ snapshot: ResultSnapshot) {
        resultHeaders = snapshot.headers
        resultTypes = snapshot.types
        resultForeignKeys = snapshot.foreignKeys
        resultRows = snapshot.rows
        resultNote.stringValue = snapshot.note
        configureResultColumns()
        reloadResults()
    }

    @objc private func closeRowDetails(_ sender: Any? = nil) {
        detailPanel?.isHidden = true
        rootDrawerWidthConstraint?.isActive = false
        detailPanelWidthConstraint?.isActive = false
        rootFullWidthConstraint?.isActive = true
    }

    @objc private func copySelectedRowsAsJSON() {
        let indexes = filteredResultIndexes
        let selected = resultsTableView.selectedRowIndexes.compactMap { $0 < indexes.count ? indexes[$0] : nil }
        guard !selected.isEmpty else { return }
        let objects: [[String: String]] = selected.map { index in
            Dictionary(uniqueKeysWithValues: resultHeaders.enumerated().map { ($0.element, $0.offset < resultRows[index].count ? resultRows[index][$0.offset] : "NULL") })
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objects.count == 1 ? objects[0] : objects, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        resultNote.stringValue = selected.count == 1 ? "Linha copiada como JSON" : "\(selected.count) linhas copiadas como JSON"
    }

    @discardableResult
    private func pollBackend() -> Bool {
        guard let pointer = pg_poll() else { return false }
        defer { pg_string_free(pointer) }
        let data = Data(String(cString: pointer).utf8)
        guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = event["kind"] as? String else { return true }
        switch kind {
        case "status":
            let text = event["text"] as? String ?? ""
            let hasUnverifiedTLS = text.localizedCaseInsensitiveContains("certificado do servidor não verificado")
            tlsWarningField.stringValue = hasUnverifiedTLS ? "TLS ativo · certificado do servidor não verificado" : ""
            tlsWarningField.isHidden = !hasUnverifiedTLS
            if text.hasPrefix("Conectado") {
                setConnected(true)
                saveConnectionURLToDisk(connectionURL)
            }
        case "table_stats":
            let rows = event["items"] as? [[String]] ?? []
            tableEstimates = Dictionary(rows.compactMap { row in row.count == 2 ? Int64(row[1]).map { (row[0], $0) } : nil }, uniquingKeysWith: { first, _ in first })
            tableListView.reloadData()
        case "tables":
            tables = event["items"] as? [String] ?? []
            cachedFilteredTables = nil
            tableListView.reloadData()
        case "schema":
            let rows = event["items"] as? [[String]] ?? []
            queryView.engine = SQLCompletionEngine(catalog: SchemaCatalog(rows: rows))
        case "results", "table_preview":
            closeRowDetails()
            hasExecutedQuery = kind == "results"
            updateResultActionVisibility()
            apply(ResultSnapshot(headers: event["headers"] as? [String] ?? [], types: event["types"] as? [String] ?? [],
                                 foreignKeys: event["foreign_keys"] as? [[String]] ?? [], rows: event["rows"] as? [[String]] ?? [],
                                 note: event["note"] as? String ?? "", selectedRow: nil))
            if kind == "table_preview", let table = previewTable, let estimate = tableEstimates[table], estimate >= 0 {
                resultNote.stringValue = "Mostrando \(resultRows.count) · tabela com \(RowEstimate.long(estimate))"
            }
            if openDetailsOnNextResult {
                openDetailsOnNextResult = false
                if resultRows.isEmpty {
                    resultNote.stringValue = "Linha referenciada não encontrada"
                } else {
                    resultsTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    showRowDetails(at: filteredResultIndexes.first ?? 0)
                }
            }
        case "error":
            hasExecutedQuery = false
            updateResultActionVisibility()
            resultHeaders = []
            resultRows = []
            configureResultColumns()
            reloadResults()
            resultNote.stringValue = event["text"] as? String ?? "Falha na conexão"
            setConnected(false)
        case "query_error" where openDetailsOnNextResult:
            // Following a foreign key failed: stay on the current results.
            openDetailsOnNextResult = false
            navigationStack.removeLast()
            let message = event["text"] as? String ?? "Falha na consulta"
            resultNote.stringValue = "Não foi possível abrir a linha referenciada: " + (message.components(separatedBy: .newlines).first ?? message)
            resultNote.toolTip = message
        case "query_error":
            hasExecutedQuery = false
            updateResultActionVisibility()
            resultHeaders = []
            resultRows = []
            configureResultColumns()
            reloadResults()
            let message = event["text"] as? String ?? "Falha na consulta"
            resultNote.stringValue = message.components(separatedBy: .newlines).first ?? message
            resultNote.toolTip = message
            let alert = NSAlert()
            alert.messageText = "Erro ao executar SQL"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.beginSheetModal(for: window) { [weak self] _ in self?.highlightErrorPosition(in: message) }
        default: break
        }
        return true
    }
}
