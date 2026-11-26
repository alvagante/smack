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

@MainActor
enum NativeMenuBarSystemBridge {
    static func menuBarWindows() -> [NativeMenuBarWindow] {
        let connection = CGSMainConnectionID()
        var count: Int32 = 0
        guard CGSGetWindowCount(connection, 0, &count) == .success, count > 0 else { return [] }
        var identifiers = [CGWindowID](repeating: 0, count: Int(count))
        var actualCount: Int32 = 0
        guard CGSGetProcessMenuBarWindowList(connection, 0, count, &identifiers, &actualCount) == .success else { return [] }
        return identifiers.prefix(Int(actualCount)).compactMap(window)
    }

    static func window(_ id: CGWindowID) -> NativeMenuBarWindow? {
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

    static func currentFrame(for id: CGWindowID) -> CGRect? {
        var frame = CGRect.zero
        guard CGSGetScreenRectForWindow(CGSMainConnectionID(), id, &frame) == .success else { return nil }
        return frame
    }

    static func capture(_ window: NativeMenuBarWindow, from captureWindow: SCWindow?, scale: CGFloat) async -> CGImage? {
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

    static func postClick(_ item: NativeMenuBarItem, button: CGMouseButton, frame: CGRect) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
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

    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    static func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}

extension NSScreen {
    var nativeDisplayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
    }
}
#endif
