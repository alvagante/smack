import AppKit
import SwiftUI

private final class FloatingPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let store: MonitorStore
    private let statusItem: NSStatusItem
    private let panel: NSPanel
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var hoverTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var pinned = false

    init(store: MonitorStore, statusItem: NSStatusItem) {
        self.store = store
        self.statusItem = statusItem
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
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
        panel.minSize = NSSize(width: 400, height: 420)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: MonitorRootView(store: store))
        installMonitors()
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
        positionPanel()
        if !panel.isVisible { panel.orderFrontRegardless() }
        store.setVisible(true)
        dismissTask?.cancel()
    }

    func close() {
        panel.close()
    }

    private func positionPanel() {
        let screen = screenContainingPointer() ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame
        let topInset = screen.safeAreaInsets.top
        let x = min(max(panel.frame.width / 2 + frame.minX + 12, NSEvent.mouseLocation.x - panel.frame.width / 2), frame.maxX - panel.frame.width / 2 - 12)
        let y = frame.maxY - max(topInset, 24) - panel.frame.height - 6
        panel.setFrameOrigin(NSPoint(x: x - panel.frame.width / 2, y: y))
    }

    private func screenContainingPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
    }

    private func cameraHotZone() -> NSRect? {
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
        store.setVisible(false)
    }
}
