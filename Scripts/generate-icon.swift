import AppKit

func drawIcon() {
    let background = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 205, yRadius: 205)
    let graphics = NSGraphicsContext.current
    graphics?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    NSColor.black.setFill()
    background.fill()
    graphics?.restoreGraphicsState()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.12, green: 0.20, blue: 0.28, alpha: 1),
        NSColor(calibratedRed: 0.035, green: 0.055, blue: 0.085, alpha: 1)
    ])!
    gradient.draw(in: background, angle: -55)

    graphics?.saveGraphicsState()
    background.addClip()
    let halo = NSBezierPath(ovalIn: NSRect(x: 190, y: 350, width: 650, height: 650))
    let haloGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.10, green: 0.75, blue: 0.95, alpha: 0.18),
        NSColor(calibratedRed: 0.10, green: 0.75, blue: 0.95, alpha: 0)
    ])!
    haloGradient.draw(in: halo, relativeCenterPosition: .zero)
    graphics?.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.13).setStroke()
    background.lineWidth = 5
    background.stroke()

    let waveform = NSBezierPath()
    waveform.move(to: NSPoint(x: 205, y: 505))
    waveform.line(to: NSPoint(x: 350, y: 505))
    waveform.line(to: NSPoint(x: 418, y: 610))
    waveform.line(to: NSPoint(x: 510, y: 315))
    waveform.line(to: NSPoint(x: 600, y: 700))
    waveform.line(to: NSPoint(x: 674, y: 505))
    waveform.line(to: NSPoint(x: 819, y: 505))
    waveform.lineCapStyle = .round
    waveform.lineJoinStyle = .round

    graphics?.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor(calibratedRed: 0.05, green: 0.85, blue: 1, alpha: 0.9)
    glow.shadowBlurRadius = 36
    glow.set()
    NSColor(calibratedRed: 0.04, green: 0.72, blue: 0.95, alpha: 0.3).setStroke()
    waveform.lineWidth = 64
    waveform.stroke()
    graphics?.restoreGraphicsState()

    NSColor(calibratedRed: 0.08, green: 0.82, blue: 1, alpha: 1).setStroke()
    waveform.lineWidth = 34
    waveform.stroke()

    NSColor.white.withAlphaComponent(0.88).setStroke()
    waveform.lineWidth = 9
    waveform.stroke()

    for point in [NSPoint(x: 205, y: 505), NSPoint(x: 819, y: 505)] {
        NSColor(calibratedRed: 0.65, green: 0.95, blue: 1, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 17, y: point.y - 17, width: 34, height: 34)).fill()
    }
}

func writeIcon(size: Int, to url: URL) throws {
    guard let bitmap = NSBitmapImageRep(
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
    ) else { throw NSError(domain: "SmackIcon", code: 1) }
    bitmap.size = NSSize(width: size, height: size)
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context?.imageInterpolation = .high
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(size) / 1024)
    transform.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "SmackIcon", code: 2) }
    try data.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Sources/Smack/Resources", isDirectory: true)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let icons = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]
for (name, size) in icons {
    try writeIcon(size: size, to: iconset.appendingPathComponent(name))
}
try writeIcon(size: 1024, to: resources.appendingPathComponent("AppIcon.png"))
print(iconset.path)
