import AppKit

struct Accent {
    let glow: NSColor
    let halo: NSColor
    let core: NSColor
    let tip: NSColor
    let digits: NSColor
    let backgroundTop: NSColor
    let backgroundBottom: NSColor
}

// Pick with SMACK_ICON_ACCENT=green|yellow|cyan (default: green).
let accents: [String: Accent] = [
    "green": Accent(
        glow: NSColor(calibratedRed: 0.45, green: 1, blue: 0.05, alpha: 0.9),
        halo: NSColor(calibratedRed: 0.40, green: 0.95, blue: 0.10, alpha: 1),
        core: NSColor(calibratedRed: 0.55, green: 1, blue: 0.10, alpha: 1),
        tip: NSColor(calibratedRed: 0.85, green: 1, blue: 0.65, alpha: 1),
        digits: NSColor(calibratedRed: 0.45, green: 1, blue: 0.20, alpha: 1),
        backgroundTop: NSColor(calibratedRed: 0.08, green: 0.16, blue: 0.10, alpha: 1),
        backgroundBottom: NSColor(calibratedRed: 0.02, green: 0.04, blue: 0.03, alpha: 1)
    ),
    "yellow": Accent(
        glow: NSColor(calibratedRed: 1, green: 0.85, blue: 0.05, alpha: 0.9),
        halo: NSColor(calibratedRed: 1, green: 0.80, blue: 0.10, alpha: 1),
        core: NSColor(calibratedRed: 1, green: 0.88, blue: 0.10, alpha: 1),
        tip: NSColor(calibratedRed: 1, green: 0.97, blue: 0.70, alpha: 1),
        digits: NSColor(calibratedRed: 1, green: 0.85, blue: 0.25, alpha: 1),
        backgroundTop: NSColor(calibratedRed: 0.16, green: 0.14, blue: 0.08, alpha: 1),
        backgroundBottom: NSColor(calibratedRed: 0.04, green: 0.035, blue: 0.02, alpha: 1)
    ),
    "cyan": Accent(
        glow: NSColor(calibratedRed: 0.05, green: 0.85, blue: 1, alpha: 0.9),
        halo: NSColor(calibratedRed: 0.10, green: 0.75, blue: 0.95, alpha: 1),
        core: NSColor(calibratedRed: 0.08, green: 0.82, blue: 1, alpha: 1),
        tip: NSColor(calibratedRed: 0.65, green: 0.95, blue: 1, alpha: 1),
        digits: NSColor(calibratedRed: 0.30, green: 0.85, blue: 1, alpha: 1),
        backgroundTop: NSColor(calibratedRed: 0.12, green: 0.20, blue: 0.28, alpha: 1),
        backgroundBottom: NSColor(calibratedRed: 0.035, green: 0.055, blue: 0.085, alpha: 1)
    )
]
let accent = accents[ProcessInfo.processInfo.environment["SMACK_ICON_ACCENT"] ?? "green"] ?? accents["green"]!

// Deterministic LCG so the binary layer is identical on every regeneration.
struct SeededRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
    mutating func unit() -> CGFloat { CGFloat(next() % 10_000) / 10_000 }
}

// Columns of 0/1 behind the waveform, each column fading toward its tail.
func drawBinaryLayer(in background: NSBezierPath) {
    let graphics = NSGraphicsContext.current
    graphics?.saveGraphicsState()
    background.addClip()
    var random = SeededRandom(state: 42)
    let font = NSFont.monospacedSystemFont(ofSize: 30, weight: .semibold)
    let columnWidth: CGFloat = 36
    let rowHeight: CGFloat = 36
    let center = NSPoint(x: 512, y: 512)
    var x: CGFloat = 84
    while x < 940 {
        let columnAlpha = 0.08 + random.unit() * 0.16
        let headRow = Int(random.next() % 24)
        var y: CGFloat = 900
        var row = 0
        while y > 80 {
            // Matrix-style trail: brightest at the head, fading over ~10 rows, sparse gaps elsewhere.
            let distance = (row - headRow + 24) % 24
            let fade = max(0, 1 - CGFloat(distance) / 14)
            // Dim digits near the centre so the waveform keeps the focus.
            let radius = hypot(x - center.x, y - center.y)
            let vignette = min(1, max(0.25, (radius - 120) / 280))
            if fade > 0, random.unit() > 0.12 {
                let digit = random.next() % 2 == 0 ? "0" : "1"
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: accent.digits.withAlphaComponent(columnAlpha * (0.35 + 0.65 * fade) * vignette)
                ]
                (digit as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
            }
            y -= rowHeight
            row += 1
        }
        x += columnWidth
    }
    graphics?.restoreGraphicsState()
}

func drawIcon(size: Int) {
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

    let gradient = NSGradient(colors: [accent.backgroundTop, accent.backgroundBottom])!
    gradient.draw(in: background, angle: -55)

    graphics?.saveGraphicsState()
    background.addClip()
    let halo = NSBezierPath(ovalIn: NSRect(x: 190, y: 350, width: 650, height: 650))
    let haloGradient = NSGradient(colors: [
        accent.halo.withAlphaComponent(0.18),
        accent.halo.withAlphaComponent(0)
    ])!
    haloGradient.draw(in: halo, relativeCenterPosition: .zero)
    graphics?.restoreGraphicsState()

    // Digits turn into noise at small sizes; keep the tiny renditions clean.
    if size > 64 {
        drawBinaryLayer(in: background)
    }

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
    glow.shadowColor = accent.glow
    glow.shadowBlurRadius = 36
    glow.set()
    accent.core.withAlphaComponent(0.3).setStroke()
    waveform.lineWidth = 64
    waveform.stroke()
    graphics?.restoreGraphicsState()

    accent.core.setStroke()
    waveform.lineWidth = 34
    waveform.stroke()

    NSColor.white.withAlphaComponent(0.88).setStroke()
    waveform.lineWidth = 9
    waveform.stroke()

    for point in [NSPoint(x: 205, y: 505), NSPoint(x: 819, y: 505)] {
        accent.tip.setFill()
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
    drawIcon(size: size)
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
