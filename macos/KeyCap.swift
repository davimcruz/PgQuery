import AppKit

/// Renders keyboard shortcuts as small key caps (like HTML `<kbd>`) to
/// show next to button titles.
enum KeyCap {
    static func image(_ keys: [String], onAccent: Bool = false, fontSize: CGFloat = 10.5) -> NSImage {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let capHeight = ceil(fontSize + 6)
        let gap: CGFloat = 2
        let lead: CGFloat = 3  // breathing room after the button title
        let widths = keys.map { max(capHeight, ceil(($0 as NSString).size(withAttributes: attributes).width) + 8) }
        let size = NSSize(width: lead + widths.reduce(0, +) + gap * CGFloat(max(0, keys.count - 1)), height: capHeight + 1)
        let image = NSImage(size: size, flipped: false) { _ in
            // Drawn at display time so the colors follow light/dark mode.
            var x: CGFloat = lead
            for (key, width) in zip(keys, widths) {
                let rect = NSRect(x: x + 0.5, y: 1.5, width: width - 1, height: capHeight - 1)
                let path = NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5)
                // On default (blue) buttons the image is a template: AppKit tints
                // it white on blue and gray when the window is inactive.
                let edge = onAccent ? NSColor.black.withAlphaComponent(0.6) : NSColor.tertiaryLabelColor
                if !onAccent {
                    NSColor.labelColor.withAlphaComponent(0.05).setFill()
                    path.fill()
                }
                edge.setStroke()
                path.lineWidth = 0.75
                path.stroke()
                // A slightly thicker bottom edge gives the cap some depth.
                edge.withAlphaComponent(onAccent ? 0.6 : 0.5).setFill()
                NSRect(x: rect.minX + 2.5, y: 0.5, width: rect.width - 5, height: 1).fill()
                let text = key as NSString
                let textSize = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: x + (width - textSize.width) / 2, y: 1.5 + (capHeight - 1 - textSize.height) / 2),
                          withAttributes: [.font: font, .foregroundColor: onAccent ? NSColor.black : NSColor.secondaryLabelColor])
                x += width + gap
            }
            return true
        }
        image.isTemplate = onAccent
        image.accessibilityDescription = "Atalho " + keys.joined()
        return image
    }
}

extension NSButton {
    /// Shows the shortcut as key caps after the title.
    func showShortcut(_ keys: String...) {
        image = KeyCap.image(keys, onAccent: keyEquivalent == "\r")
        imagePosition = .imageTrailing
        imageHugsTitle = true
        let hint = keys.joined()
        if let toolTip, !toolTip.contains(hint) { self.toolTip = toolTip + " (\(hint))" } else if toolTip == nil { toolTip = hint }
    }
}
