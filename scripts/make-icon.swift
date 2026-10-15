import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

/// A four-pointed sparkle with curved sides.
func sparkle(center: NSPoint, radius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let tips = (0..<4).map { index -> NSPoint in
        let angle = CGFloat(index) * .pi / 2 + .pi / 2
        return NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }
    path.move(to: tips[0])
    for index in 0..<4 {
        let next = tips[(index + 1) % 4]
        let angle = CGFloat(index) * .pi / 2 + .pi / 2 + .pi / 4
        let control = NSPoint(x: center.x + cos(angle) * radius * 0.16, y: center.y + sin(angle) * radius * 0.16)
        path.curve(to: next, controlPoint1: control, controlPoint2: control)
    }
    path.close()
    return path
}

/// A ring segment between two angles (degrees, counter-clockwise from 3 o'clock).
func arc(center: NSPoint, radius: CGFloat, width: CGFloat, from start: CGFloat, to end: CGFloat, cap: NSBezierPath.LineCapStyle = .butt) -> NSBezierPath {
    let path = NSBezierPath()
    path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
    path.lineWidth = width
    path.lineCapStyle = cap
    return path
}

func render(size: Int) -> Data? {
    let pixels = CGFloat(size)
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high

    let inset = pixels * 0.1
    let rect = NSRect(x: inset, y: inset, width: pixels - inset * 2, height: pixels - inset * 2)
    let tile = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    shadow.shadowOffset = NSSize(width: 0, height: -pixels * 0.012)
    shadow.shadowBlurRadius = pixels * 0.03
    shadow.set()
    NSColor.black.setFill()
    tile.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGradient(colors: [color(52, 199, 217), color(56, 107, 245), color(107, 72, 230)])?.draw(in: tile, angle: -60)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])?.draw(in: tile, angle: -90)

    let center = NSPoint(x: rect.midX, y: rect.midY - rect.height * 0.01)
    let radius = rect.width * 0.29
    let width = rect.width * 0.11

    // Track for the part already swept clean.
    NSColor.white.withAlphaComponent(0.18).setStroke()
    arc(center: center, radius: radius, width: width, from: 0, to: 360).stroke()

    // Storage segments in the app's own colours, leaving the top-right quarter swept clean.
    let segments: [(CGFloat, CGFloat, NSColor)] = [
        (96, 192, color(255, 255, 255)),
        (197, 262, color(255, 214, 102)),
        (267, 318, color(255, 159, 10)),
        (323, 352, color(125, 241, 255)),
    ]
    for (start, end, fill) in segments {
        fill.setStroke()
        arc(center: center, radius: radius, width: width, from: start, to: end).stroke()
    }

    // The sweep: a fading trail through the cleared arc.
    let steps = 90
    for step in 0..<steps {
        let start = 2 + CGFloat(step)
        let alpha = pow(CGFloat(step) / CGFloat(steps), 1.6) * 0.65
        NSColor.white.withAlphaComponent(alpha).setStroke()
        arc(center: center, radius: radius, width: width * 0.5, from: start, to: start + 1.2).stroke()
    }

    // Code brackets in the middle.
    let glyph = rect.width * 0.1
    let bracket = NSBezierPath()
    bracket.lineWidth = rect.width * 0.032
    bracket.lineCapStyle = .round
    bracket.lineJoinStyle = .round
    bracket.move(to: NSPoint(x: center.x - glyph * 0.55, y: center.y + glyph * 0.6))
    bracket.line(to: NSPoint(x: center.x - glyph * 1.15, y: center.y))
    bracket.line(to: NSPoint(x: center.x - glyph * 0.55, y: center.y - glyph * 0.6))
    bracket.move(to: NSPoint(x: center.x + glyph * 0.55, y: center.y + glyph * 0.6))
    bracket.line(to: NSPoint(x: center.x + glyph * 1.15, y: center.y))
    bracket.line(to: NSPoint(x: center.x + glyph * 0.55, y: center.y - glyph * 0.6))
    bracket.move(to: NSPoint(x: center.x + glyph * 0.22, y: center.y + glyph * 0.72))
    bracket.line(to: NSPoint(x: center.x - glyph * 0.22, y: center.y - glyph * 0.72))
    NSColor.white.setStroke()
    bracket.stroke()

    // Sparkle at the head of the sweep.
    let head = NSPoint(x: center.x + cos(.pi * 0.52) * radius, y: center.y + sin(.pi * 0.52) * radius)
    NSGraphicsContext.current?.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor.white.withAlphaComponent(0.9)
    glow.shadowBlurRadius = rect.width * 0.035
    glow.set()
    NSColor.white.setFill()
    sparkle(center: head, radius: rect.width * 0.12).fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.9).setFill()
    sparkle(center: NSPoint(x: center.x + radius * 0.98, y: center.y + radius * 0.92), radius: rect.width * 0.045).fill()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        if let data = render(size: base * scale) {
            try data.write(to: URL(fileURLWithPath: "\(output)/\(name)"))
        }
    }
}
