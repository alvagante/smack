import AppKit
import SwiftUI

@MainActor
private enum ApplicationIconCache {
    private static var images: [String: NSImage] = [:]

    static func image(bundleIdentifier: String?, executablePath: String?) -> NSImage {
        let key = bundleIdentifier ?? executablePath ?? "generic-application"
        if let image = images[key] { return image }

        let bundleURL = bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        let executableBundleURL = executablePath.flatMap { path -> URL? in
            guard let range = path.range(of: ".app/Contents/") else { return nil }
            return URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app")
        }
        let image = (bundleURL ?? executableBundleURL).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            ?? NSImage()
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
