import AppKit
import Combine
import SwiftUI

private final class FloatingPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
}

private struct EventMonitorToken: @unchecked Sendable {
    let value: Any
}

enum PanelPlacement {
    static func targetFrame() -> NSRect {
        guard let screen = screenContainingPointer() ?? NSScreen.main ?? NSScreen.screens.first else {
            return NSRect(x: 0, y: 0, width: 1_000, height: 430)
        }
        let frame = screen.visibleFrame
        let width = frame.width * 0.92
        let height = min(430, frame.height * 0.55)
        let x = frame.midX - width / 2
        let y = screen.frame.maxY - max(screen.safeAreaInsets.top, 24) - height - 6
        return NSRect(x: x, y: y, width: width, height: height)
    }

    static func screenContainingPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }

    static func cameraHotZone(suppressedUntil: Date) -> NSRect? {
        guard Date() >= suppressedUntil else { return nil }
        guard let screen = screenContainingPointer(),
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        return cameraHotZoneRect(
            screenFrame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            left: left,
            right: right
        )
    }

    static func cameraHotZoneRect(screenFrame: NSRect, safeAreaTop: CGFloat, left: NSRect, right: NSRect) -> NSRect? {
        let minX = left.maxX - 12
        let maxX = right.minX + 12
        guard maxX > minX else { return nil }
        let height = max(safeAreaTop, 32)
        return NSRect(x: minX, y: screenFrame.maxY - height - 3, width: maxX - minX, height: height + 6)
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let store: MonitorStore
    private let nativeMenuBarStore: NativeMenuBarStore
    private let statusItem: NSStatusItem
    let panel: NSPanel
    private var smackSound: SmackSound?
    nonisolated(unsafe) private var eventMonitorTokens: [EventMonitorToken] = []
    nonisolated(unsafe) private var hoverTask: Task<Void, Never>?
    nonisolated(unsafe) private(set) var dismissTask: Task<Void, Never>?
    private(set) var pinned = false
    /// Forwarded menu-bar clicks land in the menu bar, possibly inside the camera hot zone; ignore them there.
    private var hotZoneSuppressedUntil = Date.distantPast
    private var glassModeSubscription: AnyCancellable?

    init(store: MonitorStore, nativeMenuBarStore: NativeMenuBarStore, statusItem: NSStatusItem) {
        self.store = store
        self.nativeMenuBarStore = nativeMenuBarStore
        self.statusItem = statusItem
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 430),
            styleMask: [.titled, .closable, .nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()
        panel.title = "Smack"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.minSize = NSSize(width: 720, height: 390)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: MonitorRootView(store: store, nativeMenuBarStore: nativeMenuBarStore))
        glassModeSubscription = store.settingsStore.$settings
            .map(\.glassMode)
            .removeDuplicates()
            .sink { [weak self] enabled in self?.applyGlassMode(enabled) }
        installMonitors()
        nativeMenuBarStore.onItemActivated = { [weak self] in
            guard let self else { return }
            self.hotZoneSuppressedUntil = Date().addingTimeInterval(1)
            self.hoverTask?.cancel()
            self.close()
        }
    }

    deinit {
        hoverTask?.cancel()
        dismissTask?.cancel()
        let tokens = eventMonitorTokens
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                tokens.forEach { NSEvent.removeMonitor($0.value) }
            }
        } else {
            DispatchQueue.main.async {
                tokens.forEach { NSEvent.removeMonitor($0.value) }
            }
        }
    }

    /// Glass needs a transparent window; the SwiftUI root draws the glass itself (`GlassBackground`).
    private func applyGlassMode(_ enabled: Bool) {
        panel.isOpaque = !enabled
        panel.backgroundColor = enabled ? .clear : .windowBackgroundColor
        panel.invalidateShadow()
    }

    func togglePinned() {
        if panel.isVisible {
            close()
        } else {
            pinned = true
            open()
        }
    }

    func open() {
        dismissTask?.cancel()
        dismissTask = nil
        guard !panel.isVisible else { return }
        let target = PanelPlacement.targetFrame()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            panel.setFrame(target, display: false)
            panel.alphaValue = 1
        } else {
            let initialSize = NSSize(width: target.width * 0.96, height: target.height * 0.96)
            let initialFrame = NSRect(
                x: target.midX - initialSize.width / 2,
                y: target.maxY - initialSize.height + 12,
                width: initialSize.width,
                height: initialSize.height
            )
            panel.setFrame(initialFrame, display: false)
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        nativeMenuBarStore.setPanelVisible(true, screen: PanelPlacement.screenContainingPointer() ?? NSScreen.main)
        store.setVisible(true)
        let sound = smackSound ?? SmackSound()
        smackSound = sound
        sound.play()
        guard !reduceMotion else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        panel.close()
    }

    private func installMonitors() {
        let monitors: [Any?] = [
            NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
                Task { @MainActor in self?.mouseMoved() }
            },
            NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                Task { @MainActor in self?.mouseMoved() }
                return event
            },
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
                Task { @MainActor in self?.mouseClicked() }
            },
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                Task { @MainActor in self?.mouseClicked() }
                return event
            }
        ]
        eventMonitorTokens = monitors.compactMap { $0.map(EventMonitorToken.init) }
    }

    private func mouseMoved() {
        let location = NSEvent.mouseLocation
        let inHotZone = PanelPlacement.cameraHotZone(suppressedUntil: hotZoneSuppressedUntil)?.contains(location) == true
        let inPanel = panel.frame.contains(location)
        updateHoverState(inHotZone: inHotZone, inPanel: inPanel)
    }

    func updateHoverState(inHotZone: Bool, inPanel: Bool) {
        updateHoverOpen(inHotZone: inHotZone)
        updateHoverDismiss(inHotZone: inHotZone, inPanel: inPanel)
    }

    private func updateHoverOpen(inHotZone: Bool) {
        guard inHotZone, store.settingsStore.settings.trigger == .hover, !panel.isVisible else {
            if !inHotZone { hoverTask?.cancel() }
            return
        }
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in await self?.scheduleHoverOpen() }
    }

    private func scheduleHoverOpen() async {
        try? await Task.sleep(for: .seconds(store.settingsStore.settings.hoverDelay))
        guard !Task.isCancelled,
              PanelPlacement.cameraHotZone(suppressedUntil: hotZoneSuppressedUntil)?.contains(NSEvent.mouseLocation) == true else { return }
        pinned = false
        open()
    }

    private func updateHoverDismiss(inHotZone: Bool, inPanel: Bool) {
        guard panel.isVisible, !pinned else { return }
        if inHotZone || inPanel {
            dismissTask?.cancel()
            dismissTask = nil
        } else if dismissTask == nil {
            dismissTask = Task { [weak self] in await self?.scheduleHoverDismiss() }
        }
    }

    private func scheduleHoverDismiss() async {
        try? await Task.sleep(for: .seconds(store.settingsStore.settings.hoverGracePeriod))
        guard !Task.isCancelled else { return }
        dismissTask = nil
        if !panel.frame.contains(NSEvent.mouseLocation) { close() }
    }

    private func mouseClicked() {
        let location = NSEvent.mouseLocation
        if PanelPlacement.cameraHotZone(suppressedUntil: hotZoneSuppressedUntil)?.contains(location) == true,
           store.settingsStore.settings.trigger == .click {
            pinned = true
            panel.isVisible ? close() : open()
        } else if panel.isVisible, pinned, !panel.frame.contains(location), statusItem.button?.window?.frame.contains(location) != true {
            close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        pinned = false
        hoverTask?.cancel()
        dismissTask?.cancel()
        dismissTask = nil
        nativeMenuBarStore.setPanelVisible(false)
        store.setVisible(false)
    }
}
