// Draws SkyrimMT's original app icon (no Bethesda art): dark slate tile, gold ring, snowy mountain peaks.
// usage: swift make_icon.swift <out.iconset> [preview.png]
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "SkyrimMT.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.09, r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tile = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.20, green: 0.23, blue: 0.27, alpha: 1), NSColor(red: 0.06, green: 0.07, blue: 0.08, alpha: 1)])!
        .draw(in: tile, angle: -90)
    // gold ring
    let c = NSPoint(x: s / 2, y: s / 2 + s * 0.02), rr = r.width * 0.33
    let ring = NSBezierPath(ovalIn: NSRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr))
    ring.lineWidth = s * 0.028
    NSColor(red: 0.85, green: 0.72, blue: 0.45, alpha: 1).setStroke(); ring.stroke()
    // mountains, clipped to the ring
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(ovalIn: NSRect(x: c.x - rr + ring.lineWidth / 2, y: c.y - rr + ring.lineWidth / 2,
                                width: 2 * rr - ring.lineWidth, height: 2 * rr - ring.lineWidth)).addClip()
    NSGradient(colors: [NSColor(red: 0.42, green: 0.48, blue: 0.55, alpha: 1), NSColor(red: 0.16, green: 0.19, blue: 0.23, alpha: 1)])!
        .draw(in: NSRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr), angle: 90)
    func peak(_ x: CGFloat, _ w: CGFloat, _ h: CGFloat, _ col: NSColor) {
        let base = c.y - rr * 0.55
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x + (x - w) * rr, y: base)); p.line(to: NSPoint(x: c.x + x * rr, y: base + h * rr))
        p.line(to: NSPoint(x: c.x + (x + w) * rr, y: base)); p.close(); col.setFill(); p.fill()
        let snow = NSBezierPath(), sh = h * 0.32
        snow.move(to: NSPoint(x: c.x + (x - w * sh / h) * rr, y: base + (h - sh) * rr)); snow.line(to: NSPoint(x: c.x + x * rr, y: base + h * rr))
        snow.line(to: NSPoint(x: c.x + (x + w * sh / h) * rr, y: base + (h - sh) * rr)); snow.close()
        NSColor(white: 0.94, alpha: 1).setFill(); snow.fill()
    }
    peak(-0.42, 0.62, 0.95, NSColor(red: 0.27, green: 0.31, blue: 0.36, alpha: 1))
    peak(0.38, 0.70, 1.05, NSColor(red: 0.30, green: 0.34, blue: 0.40, alpha: 1))
    peak(-0.02, 0.78, 1.42, NSColor(red: 0.20, green: 0.23, blue: 0.28, alpha: 1))
    NSColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1).setFill()
    NSRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: rr * 0.46).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
if CommandLine.arguments.count > 2 {
    try! draw(512).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
