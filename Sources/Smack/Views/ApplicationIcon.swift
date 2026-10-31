import AppKit
import SwiftUI

@MainActor
private enum ApplicationIconCache {
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    private static func key(_ path: String) -> NSString {
        let bundle = URL(fileURLWithPath: path)
        let fingerprint = InstalledAppsCollector.fingerprint(bundle)
        let interval = Int(Date().timeIntervalSince1970 / 300)
        return "\(path):\(fingerprint):\(interval)" as NSString
    }

    private static func store(_ image: NSImage, key: NSString) {
        let thumbnail = NSImage(size: NSSize(width: 64, height: 64))
        thumbnail.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        thumbnail.unlockFocus()
        images.setObject(thumbnail, forKey: key, cost: 128 * 128 * 4)
    }

    static func image(bundleIdentifier: String?, executablePath: String?) -> NSImage {

        let bundleURL = bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        let executableBundleURL = executablePath.flatMap { path -> URL? in
            guard let range = path.range(of: ".app/Contents/") else { return nil }
            return URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app")
        }
        let key = key((executableBundleURL ?? bundleURL)?.path ?? "generic-application")
        if let image = images.object(forKey: key) { return image }
        let image = (executableBundleURL ?? bundleURL).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            ?? NSImage()
        store(image, key: key)
        return images.object(forKey: key) ?? image
    }

    static func image(bundlePath: String) -> NSImage {
        let key = key(bundlePath)
        if let image = images.object(forKey: key) { return image }
        let image = NSWorkspace.shared.icon(forFile: bundlePath)
        store(image, key: key)
        return images.object(forKey: key) ?? image
    }
}

struct ApplicationIcon: View {
    let bundleIdentifier: String?
    let executablePath: String?
    /// Icon of this exact bundle; lookups by identifier may resolve to another copy of the app.
    var bundlePath: String?
    let size: CGFloat

    init(bundleIdentifier: String?, executablePath: String?, size: CGFloat = 24) {
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
        self.size = size
    }

    init(bundlePath: String, size: CGFloat = 24) {
        bundleIdentifier = nil
        executablePath = nil
        self.bundlePath = bundlePath
        self.size = size
    }

    init(application: ApplicationMetrics, size: CGFloat = 24) {
        bundleIdentifier = application.bundleIdentifier
        executablePath = application.executablePath
        self.size = size
    }

    var body: some View {
        Image(nsImage: bundlePath.map(ApplicationIconCache.image(bundlePath:))
            ?? ApplicationIconCache.image(bundleIdentifier: bundleIdentifier, executablePath: executablePath))
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
