import AppKit
import Foundation

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

func drawIcon() {
    let background = NSBezierPath(roundedRect: NSRect(x: 24, y: 24, width: 976, height: 976), xRadius: 236, yRadius: 236)
    NSGradient(colors: [color(0.19, 0.19, 0.19), color(0.06, 0.06, 0.06)])!.draw(in: background, angle: 45)
    color(1, 1, 1).withAlphaComponent(0.12).setStroke()
    let edge = NSBezierPath(roundedRect: NSRect(x: 26, y: 26, width: 972, height: 972), xRadius: 234, yRadius: 234)
    edge.lineWidth = 3
    edge.stroke()

    func pt(_ x: CGFloat, _ svgY: CGFloat) -> NSPoint {
        let scale: CGFloat = 0.94
        let scaledX = 512 + (x - 512) * scale
        let scaledY = 512 + (svgY - 512) * scale
        return NSPoint(x: scaledX, y: 1024 - scaledY)
    }
    func curve(_ path: NSBezierPath, _ x: CGFloat, _ y: CGFloat, _ c1x: CGFloat, _ c1y: CGFloat, _ c2x: CGFloat, _ c2y: CGFloat) {
        path.curve(to: pt(x, y), controlPoint1: pt(c1x, c1y), controlPoint2: pt(c2x, c2y))
    }

    color(0.97, 0.97, 0.97).setStroke()
    let mark = NSBezierPath()
    mark.lineWidth = 20.68
    mark.lineCapStyle = .round
    mark.lineJoinStyle = .round

    // Top ribbon contour.
    mark.move(to: pt(512, 112))
    curve(mark, 875, 263, 711, 112, 875, 178)
    curve(mark, 830, 371, 875, 317, 854, 356)
    curve(mark, 762, 353, 812, 382, 790, 365)
    curve(mark, 512, 305, 687, 322, 606, 305)
    curve(mark, 149, 203, 313, 305, 149, 276)
    curve(mark, 512, 112, 149, 150, 313, 112)
    mark.close()

    // Front panel and the lower sweeping ribbon.
    let front = NSBezierPath()
    front.lineWidth = 20.68
    front.lineCapStyle = .round
    front.lineJoinStyle = .round
    front.move(to: pt(149, 203))
    front.line(to: pt(149, 494))
    curve(front, 512, 609, 149, 567, 313, 609)
    curve(front, 570, 552, 545, 609, 570, 585)
    front.line(to: pt(570, 357))
    front.move(to: pt(570, 407))
    curve(front, 875, 536, 756, 416, 875, 471)
    curve(front, 512, 675, 875, 613, 711, 675)
    curve(front, 149, 568, 313, 675, 149, 642)
    front.stroke()
    mark.stroke()

    // Lower body outline.
    let base = NSBezierPath()
    base.lineWidth = 20.68
    base.lineCapStyle = .round
    base.lineJoinStyle = .round
    base.move(to: pt(149, 568))
    base.line(to: pt(149, 754))
    curve(base, 512, 901, 149, 837, 313, 901)
    curve(base, 875, 754, 711, 901, 875, 837)
    base.line(to: pt(875, 596))
    base.stroke()
}

func pngData(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
func appendUInt32(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

let entries: [(String, Int)] = [
    ("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
    ("ic08", 256), ("ic09", 512), ("ic10", 1024),
]
let chunks = entries.map { (type: $0.0, png: pngData(size: $0.1)) }
var iconData = Data("icns".utf8)
appendUInt32(UInt32(8 + chunks.reduce(0) { $0 + 8 + $1.png.count }), to: &iconData)
for chunk in chunks {
    iconData.append(contentsOf: chunk.type.utf8)
    appendUInt32(UInt32(8 + chunk.png.count), to: &iconData)
    iconData.append(chunk.png)
}
try iconData.write(to: output)
