// Renders the NiceDock app icon into an .iconset (run by build-app.sh).
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let shadow = NSShadow()
    shadow.shadowBlurRadius = s * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let bg = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.30, alpha: 1), NSColor(calibratedRed: 0.55, green: 0.78, blue: 0.45, alpha: 1)])!
        .draw(in: bg, angle: 90)
    NSGraphicsContext.restoreGraphicsState()
    // Sun glow
    let glow = NSGradient(colors: [NSColor(calibratedRed: 1, green: 0.97, blue: 0.85, alpha: 0.9), NSColor(calibratedRed: 1, green: 0.97, blue: 0.85, alpha: 0)])!
    NSGraphicsContext.saveGraphicsState()
    bg.addClip()
    glow.draw(fromCenter: NSPoint(x: body.midX, y: body.maxY - body.height * 0.18), radius: 0,
              toCenter: NSPoint(x: body.midX, y: body.maxY - body.height * 0.18), radius: body.width * 0.55, options: [])
    NSGraphicsContext.restoreGraphicsState()
    // Dock plate
    let plateH = body.height * 0.3
    let plate = NSRect(x: body.minX + body.width * 0.1, y: body.minY + body.height * 0.12, width: body.width * 0.8, height: plateH)
    NSColor.black.withAlphaComponent(0.88).setFill()
    NSBezierPath(roundedRect: plate, xRadius: plateH * 0.32, yRadius: plateH * 0.32).fill()
    // Tiles
    let pad = plateH * 0.14
    let tileH = plateH - pad * 2
    var x = plate.minX + pad
    let widths: [CGFloat] = [1.5, 1, 1.1]
    let colors: [NSColor] = [.white.withAlphaComponent(0.16), NSColor(calibratedRed: 0.19, green: 0.82, blue: 0.35, alpha: 1), .white.withAlphaComponent(0.16)]
    let totalW = plate.width - pad * 2 - pad * 2
    let unit = totalW / widths.reduce(0, +)
    for (i, w) in widths.enumerated() {
        let r = NSRect(x: x, y: plate.minY + pad, width: unit * w, height: tileH)
        if i == 1 {
            NSColor.white.withAlphaComponent(0.12).setStroke()
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: (r.width - tileH * 0.8) / 2, dy: tileH * 0.1))
            ring.lineWidth = tileH * 0.13
            ring.stroke()
            colors[i].setStroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: tileH * 0.4, startAngle: 90, endAngle: -120, clockwise: true)
            arc.lineWidth = tileH * 0.13
            arc.lineCapStyle = .round
            arc.stroke()
        } else {
            colors[i].setFill()
            NSBezierPath(roundedRect: r, xRadius: tileH * 0.22, yRadius: tileH * 0.22).fill()
            NSColor.white.withAlphaComponent(0.9).setFill()
            let bar = NSRect(x: r.minX + r.width * 0.18, y: r.midY - tileH * 0.02, width: r.width * 0.64, height: tileH * 0.16)
            NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
            NSColor.white.withAlphaComponent(0.45).setFill()
            let bar2 = NSRect(x: r.minX + r.width * 0.18, y: r.midY - tileH * 0.26, width: r.width * 0.4, height: tileH * 0.1)
            NSBezierPath(roundedRect: bar2, xRadius: bar2.height / 2, yRadius: bar2.height / 2).fill()
        }
        x += unit * w + pad
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
