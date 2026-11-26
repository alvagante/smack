import AppKit
import SwiftUI

@MainActor
enum ApplicationIconCache {
    private static let maxEntries = 128
    private static var images: [String: NSImage] = [:]

    static func reset() {
        images.removeAll(keepingCapacity: true)
    }

    static func image(bundleIdentifier: String?, executablePath: String?) -> NSImage {
        let key = bundleIdentifier ?? executablePath ?? "generic-application"
        if let image = images[key] { return image }

        let bundleURL = bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        let executableBundleURL = executablePath.flatMap { path -> URL? in
            guard let range = path.range(of: ".app/Contents/", options: .backwards) else { return nil }
            return URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app")
        }
        let image: NSImage
        if let url = bundleURL ?? executableBundleURL {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
                icon.draw(in: rect)
                return true
            }
        } else {
            image = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        }
        if images.count >= maxEntries {
            images.removeAll(keepingCapacity: true)
        }
        images[key] = image
        return image
    }
}

struct ApplicationIcon: View {
    let bundleIdentifier: String?
    let executablePath: String?
    let size: CGFloat

    init(application: ApplicationMetrics, size: CGFloat = 24) {
        bundleIdentifier = application.bundleIdentifier
        executablePath = application.executablePath
        self.size = size
    }

    var body: some View {
        Image(nsImage: ApplicationIconCache.image(bundleIdentifier: bundleIdentifier, executablePath: executablePath))
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
