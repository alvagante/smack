import CoreGraphics
import ApplicationServices
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

@Test func nativeMenuBarDiscoveryExcludesOnlySystemClockItems() {
    let windows = [
        menuBarWindow(id: 1, x: 100, ownerName: "Control Center", title: "Clock"),
        menuBarWindow(id: 2, x: 200, ownerName: "SystemUIServer", title: "com.apple.menuextra.clock"),
        menuBarWindow(id: 3, x: 300, ownerName: "Control Center", title: "WiFi"),
        menuBarWindow(id: 4, x: 400, ownerName: "Example", title: "Clock"),
        menuBarWindow(id: 5, x: 500, ownerName: "SystemUIServer", title: "Clock"),
        menuBarWindow(id: 6, x: 600, ownerName: "Control Center", title: nil)
    ]

    let items = NativeMenuBarDiscovery.items(from: windows, currentPID: -1, menuBarMinY: 0)

    #expect(items.map(\.id) == [3, 4, 6])
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

@Test func nativeMenuBarCropsHostedIconsOnRetinaDisplaysWithNegativeOrigins() {
    let window = CGRect(x: -1920, y: -801, width: 1920, height: 30)
    let item = CGRect(x: -500, y: -801, width: 26, height: 30)
    #expect(NativeMenuBarDiscovery.cropRect(item: item, window: window,
                                          imageSize: CGSize(width: 3840, height: 60))
            == CGRect(x: 2840, y: 0, width: 52, height: 60))
}

@Test func nativeMenuBarDoesNotCropAnIconFromOutsideItsHostWindow() {
    let window = CGRect(x: 0, y: 0, width: 100, height: 30)
    let imageSize = CGSize(width: 200, height: 60)
    #expect(NativeMenuBarDiscovery.cropRect(item: CGRect(x: -10, y: 0, width: 20, height: 30),
                                          window: window, imageSize: imageSize) == nil)
    #expect(NativeMenuBarDiscovery.cropRect(item: .zero, window: window, imageSize: imageSize) == nil)
    #expect(NativeMenuBarDiscovery.cropRect(item: window, window: .zero, imageSize: imageSize) == nil)
}

@Test func nativeMenuBarCropsFractionalBoundsWithinTheImage() {
    let window = CGRect(x: 0, y: -30, width: 100, height: 30)
    let item = CGRect(x: 73.25, y: -30, width: 26.75, height: 30)
    #expect(NativeMenuBarDiscovery.cropRect(item: item, window: window,
                                          imageSize: CGSize(width: 200, height: 60))
            == CGRect(x: 146, y: 0, width: 54, height: 60))
}

@MainActor @Test func nativeMenuBarHostedDiscoveryKeepsOverflowAndExcludesCollapsedIconsClockAndSelf() {
    let visible = hostedMenuBarSource(pid: 101, x: 820)
    let overflow = hostedMenuBarSource(pid: 102, x: 780, width: 20, identifier: "menu-bar-overflow-indicator")
    let collapsed = hostedMenuBarSource(pid: 103, x: 765, width: 38)
    let clock = hostedMenuBarSource(pid: 104, x: 1200, identifier: "com.apple.menuextra.clock")
    let own = hostedMenuBarSource(pid: 105, x: 900)
    let outside = hostedMenuBarSource(pid: 106, x: -20)
    let items = HostedMenuBarDiscovery.visibleItems(
        [clock, visible, collapsed, own, overflow, outside, visible], currentPID: 105
    )
    #expect(items.map(\.id) == [overflow.id, visible.id])
}

@Test func nativeMenuBarHostedItemsSharingAWindowHaveDistinctStableIdentities() {
    let first = hostedMenuBarSource(pid: 101, x: 800)
    let second = hostedMenuBarSource(pid: 102, x: 850)
    let repeated = hostedMenuBarSource(pid: 101, x: 900)
    #expect(first.window.id == second.window.id)
    #expect(first.id != second.id)
    #expect(first.id == repeated.id)
    #expect(first.id != NativeMenuBarItemSource(window: first.window).id)
    #expect(!NativeMenuBarDiscovery.acceptsLayout([second.id, first.id], current: [first.id, second.id], pending: nil))
}

@MainActor @Test func nativeMenuBarSelectsTheActiveSpaceCopyBeforeTheFrontmostInactiveCopy() {
    #expect(HostedMenuBarDiscovery.preferredWindow(orderedIDs: [295, 49], matchingExtras: [49: 5]) == 49)
    #expect(HostedMenuBarDiscovery.preferredWindow(orderedIDs: [50, 47], matchingExtras: [:]) == 50)
    #expect(HostedMenuBarDiscovery.preferredWindow(orderedIDs: [], matchingExtras: [:]) == nil)
}

@Test func nativeMenuBarHostedMouseEventsUseHitTestingForBothButtons() throws {
    let target = hostedMenuBarSource(pid: 101, x: 800)
    let source = try #require(CGEventSource(stateID: .hidSystemState))
    for button in [CGMouseButton.left, .right] {
        let events = NativeMenuBarClick.events(target: target, frame: target.frame, button: button, source: source)
        #expect(events.count == 2)
        #expect(events.map(\.type) == (button == .left ? [.leftMouseDown, .leftMouseUp] : [.rightMouseDown, .rightMouseUp]))
        for event in events {
            #expect(event.location == CGPoint(x: 813, y: 15))
            #expect(event.getIntegerValueField(.eventTargetUnixProcessID) == 0)
            #expect(event.getIntegerValueField(.mouseEventWindowUnderMousePointer) == 0)
            #expect(event.getIntegerValueField(.mouseEventClickState) == 1)
        }
    }
}

@Test func nativeMenuBarLegacyMouseEventsStillTargetTheIndividualWindow() throws {
    let window = menuBarWindow(id: 42, x: 800, pid: 123)
    let target = NativeMenuBarItemSource(window: window)
    let source = try #require(CGEventSource(stateID: .hidSystemState))
    let events = NativeMenuBarClick.events(target: target, frame: target.frame, button: .right, source: source)
    #expect(events.count == 2)
    for event in events {
        #expect(event.getIntegerValueField(.eventTargetUnixProcessID) == 123)
        #expect(event.getIntegerValueField(.mouseEventWindowUnderMousePointer) == 42)
        #expect(event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) == 42)
    }
}

private func hostedMenuBarSource(pid: pid_t, x: CGFloat, width: CGFloat = 26,
                                 identifier: String? = nil) -> NativeMenuBarItemSource {
    let window = NativeMenuBarWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 1400, height: 30),
                                    layer: 24, ownerPID: 1100, ownerName: "MenuBarAgent", title: nil)
    return NativeMenuBarItemSource(window: window, element: AXUIElementCreateApplication(pid),
                                  frame: CGRect(x: x, y: 0, width: width, height: 30),
                                  ownerPID: pid, identifier: identifier)
}

private func menuBarWindow(
    id: CGWindowID,
    x: CGFloat,
    y: CGFloat = 0,
    width: CGFloat = 32,
    layer: Int = Int(kCGStatusWindowLevel),
    pid: pid_t = 123,
    onScreen: Bool = true,
    ownerName: String? = "Example",
    title: String? = "Item"
) -> NativeMenuBarWindow {
    NativeMenuBarWindow(
        id: id,
        frame: CGRect(x: x, y: y, width: width, height: 24),
        layer: layer,
        ownerPID: pid,
        ownerName: ownerName,
        title: title,
        isOnScreen: onScreen
    )
}
