import Synchronization
import AppKit
import SwiftUI

@MainActor
private enum ApplicationIconCache {
    private static let images: NSCache<NSString, NSImage> = {
        NSCache<NSString, NSImage>()
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
        // Applied on every insert so a Memory budget change takes effect without a relaunch.
        let budget = MemoryBudget.current.withLock { $0 }
        images.countLimit = budget.iconCount
        images.totalCostLimit = budget.iconBytes
        images.setObject(thumbnail, forKey: key, cost: 128 * 128 * 4)
    }

    static func image(bundleIdentifier: String?, executablePath: String?) -> NSImage {

        let bundleURL = bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        let executableBundleURL = executablePath.flatMap(ApplicationReadings.bundleURL(executablePath:))
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

/// Desktop applications that belong to an AI Agent, in order of preference. Most agents are command-line
/// tools with no bundle, so a missing application is normal and falls back to a symbol.
enum AgentApplications {
    static let bundleIdentifiers: [String: [String]] = [
        "claude": ["com.anthropic.claudefordesktop"],
        "codex": ["com.openai.codex"],
        "cursor": ["com.todesktop.230313mzl4w4u92"],
        "windsurf": ["com.exafunction.windsurf"],
        "zed": ["dev.zed.Zed"],
        "kiro": ["dev.kiro.desktop"],
        "antigravity": ["com.google.antigravity"],
        "cline": ["com.microsoft.VSCode"],
        "continue": ["com.microsoft.VSCode"],
        "copilot": ["com.microsoft.VSCode"],
    ]

    @MainActor private static var resolved: [String: String?] = [:]

    /// The bundle identifier of the first installed application for this agent.
    @MainActor static func installedBundleIdentifier(for agentID: String) -> String? {
        if let known = resolved[agentID] { return known }
        let found = bundleIdentifiers[agentID]?.first {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
        resolved[agentID] = .some(found)
        return found
    }
}

/// A rounded tile holding a symbol, used where a program has no application icon of its own.
struct SymbolIconTile: View {
    let systemImage: String
    let color: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.24))
            .accessibilityHidden(true)
    }
}

/// The agent's desktop application icon when one is installed, otherwise its tile.
struct AgentIcon: View {
    let agentID: String
    var size: CGFloat = 24

    var body: some View {
        if let id = AgentApplications.installedBundleIdentifier(for: agentID) {
            ApplicationIcon(bundleIdentifier: id, executablePath: nil, size: size)
        } else {
            SymbolIconTile(systemImage: "sparkles", color: AppRoute.agents.tint, size: size)
        }
    }
}

/// The icon of the application a program belongs to, or a terminal tile for a command-line program.
struct ProgramIcon: View {
    var bundleIdentifier: String? = nil
    let executablePath: String?
    var size: CGFloat = 20

    var body: some View {
        if bundleIdentifier != nil || executablePath.flatMap(ApplicationReadings.bundleURL(executablePath:)) != nil {
            ApplicationIcon(bundleIdentifier: bundleIdentifier, executablePath: executablePath, size: size)
        } else {
            SymbolIconTile(systemImage: "terminal", color: .secondary, size: size)
        }
    }
}
