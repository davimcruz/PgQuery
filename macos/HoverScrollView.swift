import AppKit

/// Scroll view whose scrollbars only show while the mouse is over it.
/// Overlay scrollers are forced (with the system "always show" setting they
/// would take permanent space) and kept visible by flashing them for as long
/// as the pointer stays inside; they fade out right after it leaves.
@MainActor
final class HoverScrollView: NSScrollView {
    private var hoverArea: NSTrackingArea?
    private var keepAliveTimer: Timer?
    private var wantsVertical = true
    private var wantsHorizontal = true

    /// Call after any code that resets the scrollers (e.g. border helpers).
    func enableHoverScrollers(vertical: Bool = true, horizontal: Bool = true) {
        wantsVertical = vertical
        wantsHorizontal = horizontal
        applyOverlayStyle()
        NotificationCenter.default.removeObserver(self, name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(preferredStyleChanged), name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }

    @objc private func preferredStyleChanged(_ notification: Notification) { applyOverlayStyle() }

    private func applyOverlayStyle() {
        scrollerStyle = .overlay
        hasVerticalScroller = wantsVertical
        hasHorizontalScroller = wantsHorizontal
        autohidesScrollers = true
    }

    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        flashScrollers()
        keepAliveTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flashScrollers() }
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        stopKeepAlive()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopKeepAlive() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }
}
