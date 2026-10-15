import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func render(size: Int) -> Data? {
    let pixels = CGFloat(size)
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    let inset = pixels * 0.1
    let rect = NSRect(x: inset, y: inset, width: pixels - inset * 2, height: pixels - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -pixels * 0.012)
    shadow.shadowBlurRadius = pixels * 0.03
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.85, alpha: 1),
        NSColor(calibratedRed: 0.22, green: 0.42, blue: 0.96, alpha: 1),
        NSColor(calibratedRed: 0.42, green: 0.28, blue: 0.90, alpha: 1),
    ])
    gradient?.draw(in: shape, angle: -60)

    let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])
    highlight?.draw(in: shape, angle: -90)

    let configuration = NSImage.SymbolConfiguration(pointSize: pixels * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [.white, NSColor.white.withAlphaComponent(0.75)]))
    if let symbol = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let symbolSize = symbol.size
        let origin = NSPoint(x: (pixels - symbolSize.width) / 2, y: (pixels - symbolSize.height) / 2)
        symbol.draw(in: NSRect(origin: origin, size: symbolSize))
    }

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
