#if !SMACK_APP_STORE
import AppKit
import ApplicationServices
import CoreGraphics
@preconcurrency import ScreenCaptureKit

private typealias CGSConnectionID = Int32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetWindowCount")
private func CGSGetWindowCount(
    _ connection: CGSConnectionID,
    _ targetConnection: CGSConnectionID,
    _ count: inout Int32
) -> CGError

@_silgen_name("CGSGetProcessMenuBarWindowList")
private func CGSGetProcessMenuBarWindowList(
    _ connection: CGSConnectionID,
    _ targetConnection: CGSConnectionID,
    _ capacity: Int32,
    _ list: UnsafeMutablePointer<CGWindowID>,
    _ count: inout Int32
) -> CGError

@_silgen_name("CGSGetScreenRectForWindow")
private func CGSGetScreenRectForWindow(
    _ connection: CGSConnectionID,
    _ window: CGWindowID,
    _ rect: inout CGRect
) -> CGError

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

    static func displayName(ownerName: String?, applicationName: String?, title: String?) -> String {
        let fallback = applicationName ?? ownerName ?? title ?? "Menu Bar Item"
        guard let title, !title.isEmpty else { return fallback }
        if ownerName == "Control Center" || applicationName == "Control Center" {
            switch title {
            case "AccessibilityShortcuts": return "Accessibility Shortcuts"
            case "BentoBox": return "Control Center"
            case "FocusModes": return "Focus"
            case "KeyboardBrightness": return "Keyboard Brightness"
            case "MusicRecognition": return "Music Recognition"
            case "NowPlaying": return "Now Playing"
            case "ScreenMirroring": return "Screen Mirroring"
            case "StageManager": return "Stage Manager"
            case "UserSwitcher": return "Fast User Switching"
            case "WiFi": return "Wi-Fi"
            default: return title
            }
        }
        if ownerName == "SystemUIServer" || applicationName == "SystemUIServer" {
            switch title {
            case "TimeMachine.TMMenuExtraHost", "TimeMachineMenuExtra.TMMenuExtraHost": return "Time Machine"
            default: return title
            }
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
                !isSystemClock($0) &&
                $0.frame.minY == menuBarMinY &&
                $0.frame.width > 0 &&
                $0.frame.height > 0
            }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    private static func isSystemClock(_ window: NativeMenuBarWindow) -> Bool {
        guard window.ownerName == "Control Center" || window.ownerName == "SystemUIServer" else { return false }
        return window.title == "Clock" || window.title == "com.apple.menuextra.clock"
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
    private var pendingLayout: [CGWindowID]?
    private var refreshTimer: Timer?
    private var requestingPermissions = false
    private var captureInProgress = false

    private var isActive: Bool { panelVisible && featureEnabled }

    func setPanelVisible(_ visible: Bool, screen: NSScreen? = nil) {
        panelVisible = visible
        if let screen {
            backingScaleFactor = screen.backingScaleFactor
        }
        if let screen, screen.nativeDisplayID != displayID {
            displayID = screen.nativeDisplayID
            pendingLayout = nil
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
            pendingLayout = nil
        }
        updateActivity()
    }

    func requestPermissions() {
        guard featureEnabled, !requestingPermissions else { return }
        requestingPermissions = true
        Task {
            if !CGPreflightScreenCaptureAccess() {
                _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            }
            if !AXIsProcessTrusted() {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            requestingPermissions = false
            refresh()
        }
    }

    func refresh() {
        accessibilityAllowed = AXIsProcessTrusted()
        guard isActive else { return }

        let discovered = NativeMenuBarDiscovery.items(
            from: menuBarWindows(),
            currentPID: ProcessInfo.processInfo.processIdentifier,
            menuBarMinY: CGDisplayBounds(displayID).minY
        )
        screenCaptureAllowed = CGPreflightScreenCaptureAccess() || discovered.contains { $0.title != nil }
        guard screenCaptureAllowed, !captureInProgress else {
            if !screenCaptureAllowed {
                items = []
                loadAttempted = false
            }
            return
        }
        // A hidden menu bar has nothing to capture: keep the last snapshot instead of blanking it.
        guard discovered.contains(where: \.isOnScreen) else { return }
        let ids = discovered.map(\.id)
        let previous = snapshots[displayID] ?? []
        guard NativeMenuBarDiscovery.acceptsLayout(ids, current: previous.map(\.id), pending: pendingLayout) else {
            pendingLayout = ids
            return
        }
        pendingLayout = nil

        captureInProgress = true
        let display = displayID
        let scale = backingScaleFactor
        Task {
            defer { captureInProgress = false }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
                screenCaptureAllowed = false
                items = []
                loadAttempted = false
                return
            }
            var captured: [NativeMenuBarItem] = []
            for window in discovered {
                var image = previous.first { $0.id == window.id }?.image
                // Off-screen copies (behind the notch, or a hidden menu bar) may still render; only a blank
                // capture is discarded in favour of the last good image.
                let captureWindow = content.windows.first { $0.windowID == window.id }
                if let fresh = await capture(window, from: captureWindow, scale: scale),
                   NativeMenuBarDiscovery.hasVisiblePixels(fresh) {
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
            guard featureEnabled else { return }
            snapshots[display] = captured
            guard display == displayID else { return }
            items = captured
            loadAttempted = true
        }
    }

    func click(_ item: NativeMenuBarItem, button: CGMouseButton) {
        guard AXIsProcessTrusted(), let frame = currentFrame(for: item.id) else {
            accessibilityAllowed = AXIsProcessTrusted()
            return
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        onItemActivated?()
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp

        for type in [downType, upType] {
            guard let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: button
            ) else { continue }
            event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(item.ownerPID))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(item.id))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(item.id))
            if let windowField = CGEventField(rawValue: 0x33) {
                event.setIntegerValueField(windowField, value: Int64(item.id))
            }
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.post(tap: .cghidEventTap)
        }
    }

    func openScreenCaptureSettings() {
        openPrivacySettings(anchor: "Privacy_ScreenCapture")
    }

    func openAccessibilitySettings() {
        openPrivacySettings(anchor: "Privacy_Accessibility")
    }

    /// Screen Recording access is only re-evaluated at launch, so a grant needs a fresh process.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            Task { @MainActor in NSApp.terminate(nil) }
        }
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

    private func menuBarWindows() -> [NativeMenuBarWindow] {
        let connection = CGSMainConnectionID()
        var count: Int32 = 0
        guard CGSGetWindowCount(connection, 0, &count) == .success, count > 0 else { return [] }
        var identifiers = [CGWindowID](repeating: 0, count: Int(count))
        var actualCount: Int32 = 0
        guard CGSGetProcessMenuBarWindowList(connection, 0, count, &identifiers, &actualCount) == .success else { return [] }
        return identifiers.prefix(Int(actualCount)).compactMap(window)
    }

    private func window(_ id: CGWindowID) -> NativeMenuBarWindow? {
        var pointer = UnsafeRawPointer(bitPattern: Int(id))
        guard let array = CFArrayCreate(kCFAllocatorDefault, &pointer, 1, nil),
              let descriptions = CGWindowListCreateDescriptionFromArray(array) as? [CFDictionary],
              let info = descriptions.first as? [CFString: Any],
              let bounds = info[kCGWindowBounds] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds),
              let layer = info[kCGWindowLayer] as? Int,
              let ownerPID = info[kCGWindowOwnerPID] as? pid_t
        else { return nil }
        return NativeMenuBarWindow(
            id: id,
            frame: currentFrame(for: id) ?? frame,
            layer: layer,
            ownerPID: ownerPID,
            ownerName: info[kCGWindowOwnerName] as? String,
            title: info[kCGWindowName] as? String,
            isOnScreen: info[kCGWindowIsOnscreen] as? Bool ?? false
        )
    }

    private func currentFrame(for id: CGWindowID) -> CGRect? {
        var frame = CGRect.zero
        guard CGSGetScreenRectForWindow(CGSMainConnectionID(), id, &frame) == .success else { return nil }
        return frame
    }

    private func capture(_ window: NativeMenuBarWindow, from captureWindow: SCWindow?, scale: CGFloat) async -> CGImage? {
        guard let captureWindow else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((window.frame.width * scale).rounded()))
        configuration.height = max(1, Int((window.frame.height * scale).rounded()))
        configuration.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: captureWindow)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { return nil }
        let thickness = min(CGFloat(image.height), NSStatusBar.system.thickness * scale)
        let crop = CGRect(
            x: 0,
            y: (CGFloat(image.height) - thickness) / 2,
            width: CGFloat(image.width),
            height: thickness
        ).integral
        return image.cropping(to: crop) ?? image
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

private extension NSScreen {
    var nativeDisplayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
    }
}
#endif
