import AppKit

/// Small floating confirmation ("Célula copiada"). The gray note beside the
/// buttons is easy to miss; this is not, and it does not overwrite it.
@MainActor
final class ToastView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var hideWork: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.masksToBounds = true
        alphaValue = 0
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Never intercepts clicks meant for what is underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ text: String, symbol: String = "checkmark.circle.fill", tint: NSColor = .systemGreen) {
        label.stringValue = text
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: text])
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.4; self?.animator().alphaValue = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}
