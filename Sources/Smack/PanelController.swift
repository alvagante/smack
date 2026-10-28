import AppKit
import Combine
import SwiftUI

private final class FloatingPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let store: MonitorStore
    private let nativeMenuBarStore: NativeMenuBarStore
    private let statusItem: NSStatusItem
    private let panel: NSPanel
    private let smackSound: SmackSound
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var hoverTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var pinned = false
    /// Forwarded menu-bar clicks land in the menu bar, possibly inside the camera hot zone; ignore them there.
    private var hotZoneSuppressedUntil = Date.distantPast
    private var glassModeSubscription: AnyCancellable?

    /// Initializes the panel controller with the necessary stores and audio player.
    ///
    /// - Parameters:
    ///   - store: Central state store for metrics and configuration.
    ///   - nativeMenuBarStore: Store managing forwarded native menu-bar icons.
    ///   - statusItem: Status item representing Smack in the macOS menu bar.
    ///   - smackSound: Audio player responsible for playing panel open sounds.
    init(
        store: MonitorStore,
        nativeMenuBarStore: NativeMenuBarStore,
        statusItem: NSStatusItem,
        smackSound: SmackSound = SmackSound()
    ) {
        self.store = store
        self.nativeMenuBarStore = nativeMenuBarStore
        self.statusItem = statusItem
        self.smackSound = smackSound
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
        guard !panel.isVisible else { return }
        let target = targetFrame()
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
        nativeMenuBarStore.setPanelVisible(true, screen: screenContainingPointer() ?? NSScreen.main)
        store.setVisible(true)
        smackSound.play(sound: store.settingsStore.settings.panelSound)
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

    private func targetFrame() -> NSRect {
        let screen = screenContainingPointer() ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        let width = frame.width * 0.92
        let height = min(430, frame.height * 0.55)
        let x = frame.midX - width / 2
        let y = screen.frame.maxY - max(screen.safeAreaInsets.top, 24) - height - 6
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func screenContainingPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }

    private func cameraHotZone() -> NSRect? {
        guard Date() >= hotZoneSuppressedUntil else { return nil }
        guard let screen = screenContainingPointer(), let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        let minX = left.maxX - 12
        let maxX = right.minX + 12
        guard maxX > minX else { return nil }
        let height = max(screen.safeAreaInsets.top, 32)
        return NSRect(x: minX, y: screen.frame.maxY - height - 3, width: maxX - minX, height: height + 6)
    }

    private func installMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in self?.mouseMoved() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            Task { @MainActor in self?.mouseMoved() }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            Task { @MainActor in self?.mouseClicked() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            Task { @MainActor in self?.mouseClicked() }
            return event
        }
    }

    private func mouseMoved() {
        let location = NSEvent.mouseLocation
        let inHotZone = cameraHotZone()?.contains(location) == true
        if inHotZone, store.settingsStore.settings.trigger == .hover, !panel.isVisible {
            hoverTask?.cancel()
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.store.settingsStore.settings.hoverDelay ?? 0.3))
                guard let self, !Task.isCancelled, self.cameraHotZone()?.contains(NSEvent.mouseLocation) == true else { return }
                self.pinned = false
                self.open()
            }
        } else if !inHotZone {
            hoverTask?.cancel()
        }
        guard panel.isVisible, !pinned else { return }
        let inPanel = panel.frame.contains(location)
        if inHotZone || inPanel {
            dismissTask?.cancel()
        } else if dismissTask == nil {
            dismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.store.settingsStore.settings.hoverGracePeriod ?? 0.5))
                guard let self, !Task.isCancelled else { return }
                if !self.panel.frame.contains(NSEvent.mouseLocation) { self.close() }
            }
        }
    }

    private func mouseClicked() {
        let location = NSEvent.mouseLocation
        if cameraHotZone()?.contains(location) == true, store.settingsStore.settings.trigger == .click {
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
