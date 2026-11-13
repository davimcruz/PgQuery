import AppKit
import Foundation
import Darwin
import Security
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

@MainActor
class PointerButton: NSButton {
    private var pointerTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
}

private final class DetailDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class PointerPopupButton: NSPopUpButton {
    private var pointerTrackingArea: NSTrackingArea?
    override func updateTrackingAreas() {
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
}

@MainActor
final class PointerSegmentedControl: NSSegmentedControl {
    private var pointerTrackingArea: NSTrackingArea?
    override func updateTrackingAreas() {
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
}

@MainActor
@main
final class PgQueryApp: NSObject, NSApplicationDelegate, NSTextViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow!
    private let connectionField = NSTextField()
    private let filterField = NSTextField()
    private let queryView = NSTextView()
    private let tableListView = PointerTableView()
    private let resultsTableView = ResultsGridView()
    private let resultFilters = NSStackView()
    private let resultFilterButton = PointerButton(title: "Filtrar", target: nil, action: nil)
    private let resultFilterField = NSSearchField()
    private var activeResultFilterColumn: Int?
    private let detailStack = NSStackView()
    private var detailPanel: NSVisualEffectView!
    private var detailScrollView: NSScrollView!
    private var sqlScrollView: NSScrollView!
    private var sqlRunButton: NSButton!
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
    private var resultHeaders: [String] = []
    private var resultRows: [[String]] = []
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
        configureUpdater()
        if let savedSQL = UserDefaults.standard.string(forKey: "pgquery.last-sql") {
            queryView.string = savedSQL
            highlightSQL()
        }
        if let savedURL = loadSavedConnectionURL() {
            connectionURL = savedURL
            connectionField.stringValue = savedURL
            hasConnectedOnce = true
            setConnected(false)
            connect()
        }
        Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(pollTimer(_:)), userInfo: nil, repeats: true)
    }

    private var connectionKeychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.davi.pgquery",
            kSecAttrAccount as String: "postgres-connection-url",
        ]
    }

    private func loadSavedConnectionURL() -> String? {
        var query = connectionKeychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func saveConnectionURLToKeychain(_ value: String) {
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(connectionKeychainQuery as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var insert = connectionKeychainQuery
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
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
        settingsButton.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Configurações")
        settingsButton.imagePosition = .imageLeading
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
        tableListView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("table-name")))
        tableListView.headerView = nil
        tableListView.rowHeight = 23
        tableListView.usesAlternatingRowBackgroundColors = false
        tableListView.selectionHighlightStyle = .regular
        tableListView.delegate = self
        tableListView.dataSource = self
        tableListView.target = self
        tableListView.action = #selector(tableSelected)
        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = false
        tableScroll.borderType = .bezelBorder
        applyRoundedBorder(to: tableScroll)
        applyRoundedCorners(filterField)
        tableScroll.documentView = tableListView
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        let sidebar = NSStackView(views: [sidebarTitle, filterField, tableScroll])
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 10
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let sqlTitle = NSTextField(labelWithString: "SQL")
        sqlTitle.font = .boldSystemFont(ofSize: 14)
        configureTextView(queryView, text: "-- Escreva SQL aqui e clique em Executar\nSELECT current_database(), current_user;")
        queryView.delegate = self
        highlightSQL()
        let sqlScroll = scrollView(for: queryView)
        sqlScrollView = sqlScroll
        applyRoundedBorder(to: sqlScroll)
        resultsTableView.headerView = NSTableHeaderView()
        resultsTableView.rowHeight = 23
        resultsTableView.usesAlternatingRowBackgroundColors = true
        resultsTableView.delegate = self
        resultsTableView.dataSource = self
        resultsTableView.allowsColumnReordering = false
        resultsTableView.allowsColumnResizing = true
        resultsTableView.allowsMultipleSelection = true
        resultsTableView.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        resultsTableView.gridColor = NSColor.separatorColor
        let rowMenu = NSMenu()
        let copyJSONItem = rowMenu.addItem(withTitle: "Copiar linha(s) selecionada(s) como JSON", action: #selector(copySelectedRowsAsJSON), keyEquivalent: "")
        copyJSONItem.target = self
        resultsTableView.menu = rowMenu
        resultsTableView.translatesAutoresizingMaskIntoConstraints = false
        let resultScroll = NSScrollView()
        resultScroll.hasVerticalScroller = true
        resultScroll.hasHorizontalScroller = true
        resultScroll.borderType = .bezelBorder
        applyRoundedBorder(to: resultScroll)
        resultScroll.documentView = resultsTableView
        resultScroll.translatesAutoresizingMaskIntoConstraints = false
        resultFilters.orientation = .horizontal
        resultFilters.alignment = .centerY
        resultFilters.spacing = 8
        resultFilters.translatesAutoresizingMaskIntoConstraints = false
        resultFilterButton.target = self
        resultFilterButton.action = #selector(chooseResultFilterColumn)
        resultFilterButton.bezelStyle = .rounded
        resultFilterField.placeholderString = "Filtrar…"
        resultFilterField.identifier = NSUserInterfaceItemIdentifier("result-filter-input")
        resultFilterField.target = self
        resultFilterField.action = #selector(resultFilterChanged)
        resultFilterField.delegate = self
        resultFilterField.isHidden = true
        resultFilterField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        applyRoundedCorners(resultFilterField)
        resultFilters.addArrangedSubview(resultFilterButton)
        resultFilters.addArrangedSubview(resultFilterField)
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
        let drawerHeader = NSStackView(views: [drawerTitle, closeDrawerButton])
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
        runButton.keyEquivalent = "r"
        runButton.keyEquivalentModifierMask = .command
        let clearButton = PointerButton(title: "Limpar", target: self, action: #selector(clearResults))
        clearResultsButton = clearButton
        clearButton.bezelStyle = .rounded
        let copyButton = PointerButton(title: "Copiar resultado", target: self, action: #selector(copyResults))
        copyResultsButton = copyButton
        copyButton.bezelStyle = .rounded
        clearButton.isHidden = true
        copyButton.isHidden = true
        [runButton, clearButton, copyButton].forEach(applyRoundedCorners)
        resultNote.textColor = .secondaryLabelColor
        resultNote.font = .systemFont(ofSize: 11)
        resultNote.lineBreakMode = .byTruncatingTail
        let controls = NSStackView(views: [runButton, resultNote, copyButton, clearButton])
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

    private func configureTextView(_ view: NSTextView, text: String) {
        view.string = text
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.isRichText = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
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
        let saveButton = PointerButton(title: "Salvar e reconectar", target: self, action: #selector(saveConnectionSettings(_:)))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
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

    @objc private func filterChanged() { tableListView.reloadData() }

    @objc private func tableSelected() {
        let visible = filteredTables
        let index = tableListView.selectedRow
        guard index >= 0, index < visible.count else { return }
        clearResults()
        visible[index].withCString { pg_select_table($0) }
    }

    @objc private func runQuery() {
        guard !queryView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        clearResults()
        resultNote.stringValue = "Executando…"
        queryView.string.withCString { pg_query($0) }
    }

    @objc private func clearResults() {
        resultHeaders = []
        resultRows = []
        configureResultColumns()
        resultsTableView.reloadData()
        activeResultFilterColumn = nil
        resultFilterField.stringValue = ""
        resultFilterField.isHidden = true
        resultFilterButton.title = "Filtrar"
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
        let lines = ([resultHeaders] + resultRows).map { row in
            row.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t")
        }
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
        resultNote.stringValue = "Resultado copiado"
    }

    @objc private func pollTimer(_ timer: Timer) {
        pollBackend()
        updateResourceStats()
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
        UserDefaults.standard.set(queryView.string, forKey: "pgquery.last-sql")
        highlightSQL()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === queryView, commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let source = textView.string as NSString
        let cursor = min(textView.selectedRange().location, source.length)
        let lineStart = source.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: cursor)).location
        let start = lineStart == NSNotFound ? 0 : lineStart + 1
        let prefix = source.substring(with: NSRange(location: start, length: cursor - start))
        let indentation = String(prefix.prefix { $0 == " " || $0 == "\t" })
        textView.insertText("\n" + indentation, replacementRange: textView.selectedRange())
        return true
    }

    private func highlightSQL() {
        guard let storage = queryView.textStorage else { return }
        let source = queryView.string as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        storage.beginEditing()
        storage.setAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ], range: fullRange)
        colorMatches(#"\b(SELECT|FROM|WHERE|JOIN|LEFT|RIGHT|INNER|OUTER|ON|AS|AND|OR|NOT|NULL|IS|IN|LIKE|ILIKE|GROUP|BY|ORDER|ASC|DESC|LIMIT|OFFSET|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|ALTER|DROP|TABLE|VIEW|INDEX|DATABASE|SCHEMA|RETURNING|DISTINCT|UNION|ALL|CASE|WHEN|THEN|ELSE|END|WITH|EXISTS|BETWEEN|TRUE|FALSE|PRIMARY|KEY|FOREIGN|REFERENCES|CONSTRAINT|DEFAULT|BEGIN|COMMIT|ROLLBACK|COUNT|SUM|AVG|MIN|MAX)\b"#, in: source, color: .systemBlue)
        colorMatches(#"\b\d+(?:\.\d+)?\b"#, in: source, color: .systemPurple)
        colorMatches(#"'(?:''|[^'])*'"#, in: source, color: .systemOrange)
        colorMatches(#"--[^\n]*|/\*[\s\S]*?\*/"#, in: source, color: .systemGreen)
        storage.endEditing()
    }

    private func colorMatches(_ pattern: String, in source: NSString, color: NSColor) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
        let range = NSRange(location: 0, length: source.length)
        for match in regex.matches(in: source as String, range: range) {
            queryView.textStorage?.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private var filteredTables: [String] {
        let needle = filterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty ? tables : tables.filter { displayName(for: $0).localizedCaseInsensitiveContains(needle) }
    }

    private func displayName(for table: String) -> String {
        table.hasPrefix("public.") ? String(table.dropFirst("public.".count)) : table
    }

    private var filteredResultIndexes: [Int] {
        var indexes = Array(resultRows.indices)
        if let column = activeResultFilterColumn {
            let needle = resultFilterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !needle.isEmpty {
                indexes = indexes.filter { $0 < resultRows.count && column < resultRows[$0].count && resultRows[$0][column].localizedCaseInsensitiveContains(needle) }
            }
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

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
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
            cell.textField?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            cell.textField?.stringValue = flattenedCellText(resultRows[indexes[row]][columnIndex])
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
        if activeResultFilterColumn.map({ $0 >= resultHeaders.count }) ?? false {
            activeResultFilterColumn = nil
            resultFilterField.isHidden = true
            resultFilterField.stringValue = ""
            resultFilterButton.title = "Filtrar"
        }
        resultFilterButton.isEnabled = !resultHeaders.isEmpty
        resultSortColumn = nil
    }

    @objc private func resultFilterChanged() { resultsTableView.reloadData() }

    @objc private func chooseResultFilterColumn() {
        guard !resultHeaders.isEmpty else { return }
        let menu = NSMenu()
        for (index, header) in resultHeaders.enumerated() {
            let item = NSMenuItem(title: header, action: #selector(selectResultFilterColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = index
            if activeResultFilterColumn == index { item.state = .on }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: resultFilterButton.bounds.height), in: resultFilterButton)
    }

    @objc private func selectResultFilterColumn(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int, index < resultHeaders.count else { return }
        activeResultFilterColumn = index
        resultFilterButton.title = "Filtrar · \(resultHeaders[index])"
        resultFilterField.placeholderString = "Filtrar por \(resultHeaders[index])…"
        resultFilterField.isHidden = false
        resultsTableView.reloadData()
        window.makeFirstResponder(resultFilterField)
    }

    private func flattenedCellText(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\u{2028}", with: " ")
            .replacingOccurrences(of: "\u{2029}", with: " ")
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field.identifier?.rawValue == "result-filter-input" else { return }
        resultsTableView.reloadData()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard tableView === resultsTableView, let descriptor = tableView.sortDescriptors.first,
              let raw = descriptor.key, let index = Int(raw.replacingOccurrences(of: "column-", with: "")) else { return }
        resultSortColumn = index
        resultSortAscending = descriptor.ascending
        resultsTableView.reloadData()
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
        for (index, header) in resultHeaders.enumerated() {
            let name = NSTextField(labelWithString: header)
            name.font = .systemFont(ofSize: 11, weight: .semibold)
            name.textColor = .secondaryLabelColor
            let value = NSTextField(wrappingLabelWithString: index < resultRows[row].count ? resultRows[row][index] : "NULL")
            value.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            value.maximumNumberOfLines = 0
            value.lineBreakMode = .byWordWrapping
            value.isSelectable = true
            value.preferredMaxLayoutWidth = 300
            detailStack.addArrangedSubview(name)
            detailStack.addArrangedSubview(value)
            let separator = NSBox()
            separator.boxType = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            detailStack.addArrangedSubview(separator)
            value.widthAnchor.constraint(equalTo: detailStack.widthAnchor).isActive = true
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

    private func pollBackend() {
        guard let pointer = pg_poll() else { return }
        defer { pg_string_free(pointer) }
        let data = Data(String(cString: pointer).utf8)
        guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = event["kind"] as? String else { return }
        switch kind {
        case "status":
            let text = event["text"] as? String ?? ""
            let hasUnverifiedTLS = text.localizedCaseInsensitiveContains("certificado do servidor não verificado")
            tlsWarningField.stringValue = hasUnverifiedTLS ? "TLS ativo · certificado do servidor não verificado" : ""
            tlsWarningField.isHidden = !hasUnverifiedTLS
            if text.hasPrefix("Conectado") {
                setConnected(true)
                saveConnectionURLToKeychain(connectionURL)
            }
        case "tables":
            tables = event["items"] as? [String] ?? []
            tableListView.reloadData()
        case "results", "table_preview":
            closeRowDetails()
            hasExecutedQuery = kind == "results"
            updateResultActionVisibility()
            resultHeaders = event["headers"] as? [String] ?? []
            resultRows = event["rows"] as? [[String]] ?? []
            resultNote.stringValue = event["note"] as? String ?? ""
            configureResultColumns()
            resultsTableView.reloadData()
        case "error":
            hasExecutedQuery = false
            updateResultActionVisibility()
            resultHeaders = []
            resultRows = []
            configureResultColumns()
            resultsTableView.reloadData()
            resultNote.stringValue = event["text"] as? String ?? "Falha na conexão"
            setConnected(false)
        case "query_error":
            hasExecutedQuery = false
            updateResultActionVisibility()
            resultHeaders = []
            resultRows = []
            configureResultColumns()
            resultsTableView.reloadData()
            resultNote.stringValue = event["text"] as? String ?? "Falha na consulta"
        default: break
        }
    }
}
