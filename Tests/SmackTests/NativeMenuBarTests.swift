import CoreGraphics
import Foundation
import Testing
@testable import Smack

@Test func nativeMenuBarDiscoveryIncludesHiddenItemsInNativeOrder() {
    let currentPID = ProcessInfo.processInfo.processIdentifier
    let hidden = menuBarWindow(id: 1, x: -240)
    let notchObscured = menuBarWindow(id: 2, x: 480)
    let visible = menuBarWindow(id: 3, x: 1_200)
    let duplicate = visible
    let ownItem = menuBarWindow(id: 4, x: 800, pid: currentPID)
    let wrongLayer = menuBarWindow(id: 5, x: 700, layer: 0)
    let otherDisplay = menuBarWindow(id: 6, x: 600, y: 900)
    let empty = menuBarWindow(id: 7, x: 500, width: 0)

    let items = NativeMenuBarDiscovery.items(
        from: [visible, ownItem, notchObscured, wrongLayer, hidden, otherDisplay, duplicate, empty],
        currentPID: currentPID,
        menuBarMinY: 0
    )

    #expect(items.map(\.id) == [1, 2, 3])
}

@Test func nativeMenuBarReplacesASnapshotOnlyWithARepeatedLayout() {
    #expect(NativeMenuBarDiscovery.acceptsLayout([1, 2], current: [], pending: nil))
    #expect(NativeMenuBarDiscovery.acceptsLayout([1, 2, 3], current: [1, 2, 3], pending: nil))
    #expect(!NativeMenuBarDiscovery.acceptsLayout([2, 3], current: [1, 2, 3], pending: nil))
    #expect(!NativeMenuBarDiscovery.acceptsLayout([2, 3], current: [1, 2, 3], pending: [3]))
    #expect(NativeMenuBarDiscovery.acceptsLayout([2, 3], current: [1, 2, 3], pending: [2, 3]))
}

@Test func nativeMenuBarTreatsTransparentCapturesAsBlank() {
    func image(drawing: Bool) -> CGImage {
        let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        if drawing {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 3, y: 3, width: 1, height: 1))
        }
        return context.makeImage()!
    }

    #expect(!NativeMenuBarDiscovery.hasVisiblePixels(image(drawing: false)))
    #expect(NativeMenuBarDiscovery.hasVisiblePixels(image(drawing: true)))
}

@Test func nativeMenuBarDisplayNamesPreferTheOwningApplication() {
    #expect(NativeMenuBarItem.displayName(ownerName: "Control Center", applicationName: "Control Center", title: "WiFi") == "Wi-Fi")
    #expect(NativeMenuBarItem.displayName(ownerName: "Control Center", applicationName: "Control Center", title: "BentoBox") == "Control Center")
    #expect(NativeMenuBarItem.displayName(ownerName: "ExampleOwner", applicationName: "Example App", title: "InternalWindow") == "Example App")
    #expect(NativeMenuBarItem.displayName(ownerName: nil, applicationName: nil, title: "Clock") == "Clock")
    #expect(NativeMenuBarItem.displayName(ownerName: nil, applicationName: nil, title: nil) == "Menu Bar Item")
}

private func menuBarWindow(
    id: CGWindowID,
    x: CGFloat,
    y: CGFloat = 0,
    width: CGFloat = 32,
    layer: Int = Int(kCGStatusWindowLevel),
    pid: pid_t = 123,
    onScreen: Bool = true
) -> NativeMenuBarWindow {
    NativeMenuBarWindow(
        id: id,
        frame: CGRect(x: x, y: y, width: width, height: 24),
        layer: layer,
        ownerPID: pid,
        ownerName: "Example",
        title: "Item \(id)",
        isOnScreen: onScreen
    )
}
