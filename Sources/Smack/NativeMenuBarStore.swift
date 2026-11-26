#if !SMACK_APP_STORE
import AppKit
import ApplicationServices
import CoreGraphics
@preconcurrency import ScreenCaptureKit

struct NativeMenuBarWindow: Equatable {
    let id: CGWindowID
    let frame: CGRect
    let layer: Int
    let ownerPID: pid_t
    let ownerName: String?
    let title: String?
    var isOnScreen = true
}

struct NativeMenuBarItem: Identifiable {
    let id: CGWindowID
    let ownerPID: pid_t
    let ownerName: String?
    let title: String?
    let image: CGImage?
    let scale: CGFloat

    var displayName: String {
        let applicationName = NSRunningApplication(processIdentifier: ownerPID)?.localizedName
        return Self.displayName(ownerName: ownerName, applicationName: applicationName, title: title)
    }

    var pointSize: NSSize {
        guard let image else { return NSSize(width: 80, height: NSStatusBar.system.thickness) }
        return NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    private static let controlCenterTitles: [String: String] = [
        "AccessibilityShortcuts": "Accessibility Shortcuts",
        "BentoBox": "Control Center",
        "FocusModes": "Focus",
        "KeyboardBrightness": "Keyboard Brightness",
        "MusicRecognition": "Music Recognition",
        "NowPlaying": "Now Playing",
        "ScreenMirroring": "Screen Mirroring",
        "StageManager": "Stage Manager",
        "UserSwitcher": "Fast User Switching",
        "WiFi": "Wi-Fi",
    ]

    private static let systemUIServerTitles: [String: String] = [
        "TimeMachine.TMMenuExtraHost": "Time Machine",
        "TimeMachineMenuExtra.TMMenuExtraHost": "Time Machine",
    ]

    static func displayName(ownerName: String?, applicationName: String?, title: String?) -> String {
        let fallback = applicationName ?? ownerName ?? title ?? "Menu Bar Item"
        guard let title, !title.isEmpty else { return fallback }
        if ownerName == "Control Center" || applicationName == "Control Center" {
            return controlCenterTitles[title] ?? title
        }
        if ownerName == "SystemUIServer" || applicationName == "SystemUIServer" {
            return systemUIServerTitles[title] ?? title
        }
        return fallback
    }
}

enum NativeMenuBarDiscovery {
    static func items(
        from windows: [NativeMenuBarWindow],
        currentPID: pid_t,
        menuBarMinY: CGFloat
    ) -> [NativeMenuBarWindow] {
        var seen = Set<CGWindowID>()
        return windows
            .filter {
                $0.layer == kCGStatusWindowLevel &&
                $0.ownerPID != currentPID &&
                $0.frame.minY == menuBarMinY &&
                $0.frame.width > 0 &&
                $0.frame.height > 0
            }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    static func hasVisiblePixels(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return false }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return stride(from: 3, to: width * height * 4, by: 4).contains { pixels[$0] > 16 }
    }

    /// A layout is trusted when it matches the snapshot or repeats the previous observation, so a menu bar
    /// caught mid-animation, with only some items at rest, never replaces a complete snapshot.
    static func acceptsLayout(_ ids: [CGWindowID], current: [CGWindowID], pending: [CGWindowID]?) -> Bool {
        current.isEmpty || ids == current || ids == pending
    }
}

private struct NativeMenuBarCaptureState {
    var pendingLayout: [CGWindowID]?
    var isRequestingPermissions = false
    var isCapturing = false
}

extension NativeMenuBarDiscovery {
    static func hasScreenCaptureAccess(preflight: Bool, discovered: [NativeMenuBarWindow]) -> Bool {
        preflight || discovered.contains { $0.title != nil }
    }

    @MainActor
    static func captureItems(
        from discovered: [NativeMenuBarWindow],
        previous: [NativeMenuBarItem],
        content: SCShareableContent,
        scale: CGFloat
    ) async -> [NativeMenuBarItem] {
        let previousImages = Dictionary(
            previous.compactMap { item in item.image.map { (item.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let windowsByID = Dictionary(
            content.windows.map { ($0.windowID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var captured: [NativeMenuBarItem] = []
        captured.reserveCapacity(discovered.count)
        for window in discovered {
            var image = previousImages[window.id]
            // Off-screen copies (behind the notch, or a hidden menu bar) may still render; only a blank
            // capture is discarded in favour of the last good image.
            if let fresh = await NativeMenuBarSystemBridge.capture(window, from: windowsByID[window.id], scale: scale),
               hasVisiblePixels(fresh) {
                image = fresh
            }
            captured.append(NativeMenuBarItem(
                id: window.id,
                ownerPID: window.ownerPID,
                ownerName: window.ownerName,
                title: window.title,
                image: image,
                scale: scale
            ))
        }
        return captured
    }
}

@MainActor
final class NativeMenuBarStore: ObservableObject {
    @Published private(set) var items: [NativeMenuBarItem] = []
    @Published private(set) var screenCaptureAllowed = false
    @Published private(set) var accessibilityAllowed = false
    @Published private(set) var loadAttempted = false
    /// Called before a click is forwarded, so the panel can get out of the way of the item's menu or window.
    var onItemActivated: (() -> Void)?

    private var panelVisible = false
    private var featureEnabled = false
    private var displayID = CGMainDisplayID()
    private var backingScaleFactor: CGFloat = 2
    /// Each display has its own copy of every status item; keep the last good capture per display.
    private var snapshots: [CGDirectDisplayID: [NativeMenuBarItem]] = [:]
    private var captureState = NativeMenuBarCaptureState()
    private var refreshTimer: Timer?

    private var isActive: Bool { panelVisible && featureEnabled }

    func setPanelVisible(_ visible: Bool, screen: NSScreen? = nil) {
        panelVisible = visible
        if let screen {
            backingScaleFactor = screen.backingScaleFactor
        }
        if let screen, screen.nativeDisplayID != displayID {
            displayID = screen.nativeDisplayID
            captureState.pendingLayout = nil
            items = snapshots[displayID] ?? []
            loadAttempted = !items.isEmpty
        }
        updateActivity()
    }

    func setFeatureEnabled(_ enabled: Bool) {
        featureEnabled = enabled
        if !enabled {
            items = []
            snapshots = [:]
            captureState.pendingLayout = nil
        }
        updateActivity()
    }

    func requestPermissions() {
        guard featureEnabled, !captureState.isRequestingPermissions else { return }
        captureState.isRequestingPermissions = true
        Task {
            if !CGPreflightScreenCaptureAccess() {
                _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            }
            if !AXIsProcessTrusted() {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            captureState.isRequestingPermissions = false
            refresh()
        }
    }

    func refresh() {
        accessibilityAllowed = AXIsProcessTrusted()
        guard isActive else { return }
        guard let layout = resolveLayoutForCapture() else { return }
        performCapture(discovered: layout.discovered, previous: layout.previous)
    }

    private func resolveLayoutForCapture() -> (discovered: [NativeMenuBarWindow], previous: [NativeMenuBarItem])? {
        let discovered = NativeMenuBarDiscovery.items(
            from: NativeMenuBarSystemBridge.menuBarWindows(),
            currentPID: ProcessInfo.processInfo.processIdentifier,
            menuBarMinY: CGDisplayBounds(displayID).minY
        )
        screenCaptureAllowed = NativeMenuBarDiscovery.hasScreenCaptureAccess(
            preflight: CGPreflightScreenCaptureAccess(),
            discovered: discovered
        )
        guard screenCaptureAllowed, !captureState.isCapturing else {
            if !screenCaptureAllowed {
                items = []
                loadAttempted = false
            }
            return nil
        }
        // A hidden menu bar has nothing to capture: keep the last snapshot instead of blanking it.
        guard discovered.contains(where: \.isOnScreen) else { return nil }
        let ids = discovered.map(\.id)
        let previous = snapshots[displayID] ?? []
        guard NativeMenuBarDiscovery.acceptsLayout(ids, current: previous.map(\.id), pending: captureState.pendingLayout) else {
            captureState.pendingLayout = ids
            return nil
        }
        captureState.pendingLayout = nil
        return (discovered, previous)
    }

    private func performCapture(discovered: [NativeMenuBarWindow], previous: [NativeMenuBarItem]) {
        captureState.isCapturing = true
        let display = displayID
        let scale = backingScaleFactor
        Task {
            defer { captureState.isCapturing = false }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
                screenCaptureAllowed = false
                items = []
                loadAttempted = false
                return
            }
            let captured = await NativeMenuBarDiscovery.captureItems(
                from: discovered,
                previous: previous,
                content: content,
                scale: scale
            )
            guard featureEnabled else { return }
            snapshots[display] = captured
            guard display == displayID else { return }
            items = captured
            loadAttempted = true
        }
    }

    func click(_ item: NativeMenuBarItem, button: CGMouseButton) {
        guard AXIsProcessTrusted(), let frame = NativeMenuBarSystemBridge.currentFrame(for: item.id) else {
            accessibilityAllowed = AXIsProcessTrusted()
            return
        }
        onItemActivated?()
        NativeMenuBarSystemBridge.postClick(item, button: button, frame: frame)
    }

    static func openScreenCaptureSettings() {
        NativeMenuBarSystemBridge.openPrivacySettings(anchor: "Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        NativeMenuBarSystemBridge.openPrivacySettings(anchor: "Privacy_Accessibility")
    }

    /// Screen Recording access is only re-evaluated at launch, so a grant needs a fresh process.
    static func relaunch() {
        NativeMenuBarSystemBridge.relaunch()
    }

    private func updateActivity() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard isActive else { return }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
}
#endif
