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
    /// Rebuilt when the Window style changes: a non-activating panel cannot become main or go full screen.
    private var panel: NSWindow
    private var windowStyle: WindowStyle
    /// The panel window, for tests that check its frame.
    var window: NSWindow { panel }
    /// Whether Live Data is running for this window, for tests.
    private(set) var showsLiveData = false
    private let smackSound: SmackSound
    private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Void
    private let activate: () -> Void
    private let frameAutosaveName: String?
    private let hostingController: NSHostingController<MonitorRootView>
    private let titleBarControls = NSTitlebarAccessoryViewController()
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var hoverTask: Task<Void, Never>?
    private var pinned = false
    /// User-chosen "keep in foreground": ignores outside clicks until unstuck or closed.
    private var stuck = false
    private var stickButton: NSButton?
    /// Forwarded menu-bar clicks land in the menu bar, possibly inside the camera hot zone; ignore them there.
    private var hotZoneSuppressedUntil = Date.distantPast
    private var glassModeSubscription: AnyCancellable?
    private var appearanceSubscription: AnyCancellable?
    private var iconsSubscription: AnyCancellable?
    private var windowStyleSubscription: AnyCancellable?
    private let titleBarLayout = TitleBarLayout()
    private var titleBarView: NSView?

    /// Initializes the panel controller with the necessary stores and audio player.
    ///
    /// - Parameters:
    ///   - store: Central state store for metrics and configuration.
    ///   - nativeMenuBarStore: Store managing forwarded native menu-bar icons.
    ///   - statusItem: Status item representing Smack in the macOS menu bar.
    ///   - smackSound: Audio player responsible for playing panel open sounds.
    ///   - setActivationPolicy: Gives Smack a Dock icon for the Standard Window.
    ///   - activate: Brings Smack to the front when the Standard Window opens.
    ///   - frameAutosaveName: Where the Standard Window remembers its frame; nil keeps none.
    init(
        store: MonitorStore,
        nativeMenuBarStore: NativeMenuBarStore,
        statusItem: NSStatusItem,
        smackSound: SmackSound = SmackSound(),
        setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { _ = NSApplication.shared.setActivationPolicy($0) },
        activate: @escaping () -> Void = { NSApplication.shared.activate() },
        frameAutosaveName: String? = "SmackWindow"
    ) {
        self.store = store
        self.nativeMenuBarStore = nativeMenuBarStore
        self.statusItem = statusItem
        self.smackSound = smackSound
        self.setActivationPolicy = setActivationPolicy
        self.activate = activate
        self.frameAutosaveName = frameAutosaveName
        windowStyle = store.settingsStore.settings.panel.windowStyle
        panel = Self.makeWindow(windowStyle)
        var close: () -> Void = {}
        let rootView = MonitorRootView(
            store: store,
            nativeMenuBarStore: nativeMenuBarStore,
            titleBarLayout: titleBarLayout,
            onClose: { close() }
        )
        hostingController = NSHostingController(rootView: rootView)
        super.init()
        close = { [weak self] in self?.close() }
        titleBarControls.layoutAttribute = .right
        let titleBarView = NSHostingView(rootView: rootView.titleBarControls(layout: titleBarLayout) { [weak self] width in
            self?.titleBarView?.setFrameSize(NSSize(width: ceil(width), height: TitleBarLayout.height))
        })
        titleBarView.setFrameSize(NSSize(width: 400, height: TitleBarLayout.height))
        titleBarControls.view = titleBarView
        self.titleBarView = titleBarView
        configureWindow()
        setActivationPolicy(windowStyle.activationPolicy)
        glassModeSubscription = store.settingsStore.$settings
            .map(\.panel.glassMode)
            .removeDuplicates()
            .sink { [weak self] enabled in self?.applyGlassMode(enabled) }
        appearanceSubscription = store.settingsStore.$settings
            .map(\.panel.appearance)
            .removeDuplicates()
            .sink { [weak self] appearance in self?.applyAppearance(appearance) }
        windowStyleSubscription = store.settingsStore.$settings
            .map(\.panel.windowStyle)
            .removeDuplicates()
            .sink { [weak self] style in self?.applyWindowStyle(style) }
        iconsSubscription = store.settingsStore.$settings
            .map { $0.panel.showTopBarIcons && $0.panel.showMenuBarItems }
            .removeDuplicates()
            .sink { [weak nativeMenuBarStore] enabled in
                nativeMenuBarStore?.setFeatureEnabled(enabled)
            }
        installMonitors()
        nativeMenuBarStore.onItemActivated = { [weak self] in
            guard let self, self.windowStyle == .panel, !self.stuck else { return }
            self.hotZoneSuppressedUntil = Date().addingTimeInterval(1)
            self.hoverTask?.cancel()
            self.close()
        }
    }

    private static func makeWindow(_ style: WindowStyle) -> NSWindow {
        let rect = NSRect(x: 0, y: 0, width: 1200, height: 430)
        return switch style {
        case .panel:
            FloatingPanel(contentRect: rect, styleMask: [.titled, .closable, .nonactivatingPanel, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: true)
        case .standardWindow:
            NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                     backing: .buffered, defer: true)
        }
    }

    /// Dresses a freshly made window in Smack's chrome and content.
    private func configureWindow() {
        panel.title = "Smack"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        // An empty unified toolbar gives the standard 52pt header with vertically centered window controls.
        panel.toolbar = NSToolbar(identifier: "SmackPanel")
        panel.toolbarStyle = .unified
        panel.hidesOnDeactivate = false
        // An ordinary window level, so Spotlight, alerts, menus and other apps' windows can come in front of it.
        (panel as? NSPanel)?.isFloatingPanel = false
        panel.level = .normal
        switch windowStyle {
        case .panel:
            // The panel still opens on the current Space, including over a full-screen app.
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        case .standardWindow:
            panel.collectionBehavior = [.fullScreenPrimary]
            panel.tabbingMode = .disallowed
            if let frameAutosaveName { panel.setFrameAutosaveName(frameAutosaveName) }
        }
        panel.minSize = NSSize(width: 720, height: 340)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentViewController = hostingController
        panel.addTitlebarAccessoryViewController(titleBarControls)
        let settings = store.settingsStore.settings.panel
        applyGlassMode(settings.glassMode)
        applyAppearance(settings.appearance)
        if windowStyle == .panel { installStickButton() }
        updateTitleBarLayout()
    }

    /// Swaps in a window of the new style, reopening it if the old one was showing.
    private func applyWindowStyle(_ style: WindowStyle) {
        setActivationPolicy(style.activationPolicy)
        guard style != windowStyle else { return }
        let wasOpen = panel.isVisible || panel.isMiniaturized
        rememberWindowFrame()
        let old = panel
        // Detached first, so closing it neither stops Live Data nor takes the shared content with it.
        old.delegate = nil
        old.contentViewController = nil
        if let index = old.titlebarAccessoryViewControllers.firstIndex(of: titleBarControls) {
            old.removeTitlebarAccessoryViewController(at: index)
        }
        old.close()
        stickButton?.removeFromSuperview()
        stickButton = nil
        pinned = false
        stuck = false
        windowStyle = style
        panel = Self.makeWindow(style)
        configureWindow()
        if wasOpen { open() } else { reportVisible(false) }
    }

    private func applyAppearance(_ appearance: PanelAppearance) {
        panel.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Glass needs a transparent window; the SwiftUI root draws the glass itself (`GlassBackground`).
    private func applyGlassMode(_ enabled: Bool) {
        panel.isOpaque = !enabled
        panel.backgroundColor = enabled ? .clear : .windowBackgroundColor
        panel.invalidateShadow()
    }

    /// A pin button next to the traffic lights; lives in the titlebar view so it follows the window chrome.
    private func installStickButton() {
        guard let zoom = panel.standardWindowButton(.zoomButton), let container = zoom.superview else { return }
        let button = NSButton(frame: NSRect(x: zoom.frame.maxX + 8, y: zoom.frame.midY - 8, width: 16, height: 16))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(toggleStuck)
        container.addSubview(button)
        stickButton = button
        updateStickButton()
    }

    @objc private func toggleStuck() {
        stuck.toggle()
        updateStickButton()
    }

    private func updateStickButton() {
        let name = stuck ? "pin.fill" : "pin"
        let label = stuck ? "Unstick window" : "Keep window open"
        stickButton?.image = NSImage(systemSymbolName: name, accessibilityDescription: label)
        stickButton?.contentTintColor = stuck ? .controlAccentColor : .secondaryLabelColor
        stickButton?.toolTip = stuck
            ? "Stuck: the window stays open when you click elsewhere.\nClick to unstick. Closing the window also unsticks it."
            : "Keep this window open, even when you click elsewhere.\nClick to stick it."
        stickButton?.setAccessibilityLabel(label)
    }

    func showPinned() {
        hoverTask?.cancel()
        pinned = true
        open()
    }

    func togglePinned() {
        if windowStyle == .standardWindow {
            // A window behind other apps comes forward instead of closing.
            let inFront = panel.isVisible && panel.isKeyWindow && NSApplication.shared.isActive
            inFront ? close() : open()
        } else if panel.isVisible {
            close()
        } else {
            pinned = true
            open()
        }
    }

    func open() {
        if windowStyle == .standardWindow {
            openStandardWindow()
            return
        }
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
        reportVisible(true)
        smackSound.play(sound: store.settingsStore.settings.panel.panelSound)
        guard !reduceMotion else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func openStandardWindow() {
        if panel.isMiniaturized {
            panel.deminiaturize(nil)
        } else if !panel.isVisible {
            panel.setFrame(targetFrame(), display: false)
            smackSound.play(sound: store.settingsStore.settings.panel.panelSound)
        }
        activate()
        panel.makeKeyAndOrderFront(nil)
        reportVisible(true)
    }

    func close() {
        rememberWindowFrame()
        panel.close()
    }

    /// Writes the current frame so the next open restores size and position.
    func rememberWindowFrame() {
        guard panel.frame.width >= panel.minSize.width * 0.5, panel.frame.height >= panel.minSize.height * 0.5 else { return }
        if windowStyle == .standardWindow, let frameAutosaveName {
            panel.saveFrame(usingName: frameAutosaveName)
        }
        let frame = panel.frame
        let saved = SavedWindowFrame(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height)
        guard store.settingsStore.settings.panel.savedWindowFrame != saved else { return }
        store.settingsStore.update { $0.panel.savedWindowFrame = saved }
    }

    /// Live Data runs while the window can be seen: not minimized, hidden, on another Space or fully covered.
    static func isOnScreen(isVisible: Bool, isMiniaturized: Bool, occlusion: NSWindow.OcclusionState) -> Bool {
        isVisible && !isMiniaturized && occlusion.contains(.visible)
    }

    private func reportVisible(_ visible: Bool) {
        guard visible != showsLiveData else { return }
        showsLiveData = visible
        if visible {
            nativeMenuBarStore.setPanelVisible(true, screen: screenContainingPointer() ?? NSScreen.main)
        } else {
            nativeMenuBarStore.setPanelVisible(false)
        }
        store.setVisible(visible)
    }

    /// Every page shares one height, so navigating never resizes the panel.
    static func panelHeight(visibleHeight: CGFloat) -> CGFloat {
        (visibleHeight * 0.8).rounded()
    }

    private func targetFrame() -> NSRect {
        let fallback = defaultTargetFrame()
        if windowStyle == .standardWindow, let frameAutosaveName, panel.setFrameUsingName(frameAutosaveName) {
            let restored = panel.frame
            return clampedFrame(restored, fallback: fallback)
        }
        if let saved = store.settingsStore.settings.panel.savedWindowFrame {
            return clampedFrame(saved.cgRect, fallback: fallback)
        }
        return fallback
    }

    private func defaultTargetFrame() -> NSRect {
        let screen = screenContainingPointer() ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        let width = frame.width * 0.92
        let height = Self.panelHeight(visibleHeight: frame.height)
        let x = frame.midX - width / 2
        let y = screen.frame.maxY - max(screen.safeAreaInsets.top, 24) - height - 6
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func clampedFrame(_ frame: CGRect, fallback: NSRect) -> NSRect {
        let screens = NSScreen.screens.map(\.visibleFrame).map {
            CGRect(x: $0.origin.x, y: $0.origin.y, width: $0.width, height: $0.height)
        }
        let clamped = SavedWindowFrame(frame).clamped(
            to: screens,
            minimumSize: CGSize(width: panel.minSize.width, height: panel.minSize.height),
            fallback: CGRect(x: fallback.origin.x, y: fallback.origin.y, width: fallback.width, height: fallback.height)
        )
        return NSRect(x: clamped.origin.x, y: clamped.origin.y, width: clamped.width, height: clamped.height)
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
        guard windowStyle == .panel else { return }
        let location = NSEvent.mouseLocation
        let inHotZone = cameraHotZone()?.contains(location) == true
        if inHotZone, store.settingsStore.settings.panel.trigger == .hover, !panel.isVisible {
            hoverTask?.cancel()
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.store.settingsStore.settings.panel.hoverDelay ?? 0.3))
                guard let self, !Task.isCancelled, self.cameraHotZone()?.contains(NSEvent.mouseLocation) == true else { return }
                self.pinned = false
                self.open()
            }
        } else if !inHotZone {
            hoverTask?.cancel()
        }
    }

    private func mouseClicked() {
        guard windowStyle == .panel else { return }
        let location = NSEvent.mouseLocation
        if cameraHotZone()?.contains(location) == true, store.settingsStore.settings.panel.trigger == .click {
            pinned = true
            panel.isVisible ? close() : open()
        } else if panel.isVisible, pinned, !stuck, !panel.frame.contains(location), statusItem.button?.window?.frame.contains(location) != true {
            close()
        }
    }

    /// The hosting controller can resize the window inside a SwiftUI update; publishing then is undefined behavior.
    func windowDidResize(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.updateTitleBarLayout() }
    }

    /// Keeps titlebar items clear of the traffic lights and pin button.
    private func updateTitleBarLayout() {
        let reserved = (stickButton?.frame.maxX ?? panel.standardWindowButton(.zoomButton)?.frame.maxX ?? 100) + 16
        let available = max(160, panel.frame.width - reserved)
        if titleBarLayout.available != available { titleBarLayout.available = available }
        if titleBarLayout.leading != reserved { titleBarLayout.leading = reserved }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard windowStyle == .standardWindow else { return }
        reportVisible(Self.isOnScreen(isVisible: panel.isVisible, isMiniaturized: panel.isMiniaturized, occlusion: panel.occlusionState))
    }

    func windowWillClose(_ notification: Notification) {
        rememberWindowFrame()
        pinned = false
        stuck = false
        updateStickButton()
        hoverTask?.cancel()
        reportVisible(false)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        rememberWindowFrame()
    }
}

private extension WindowStyle {
    /// The Standard Window lives in the Dock; the Panel belongs to the menu bar only.
    var activationPolicy: NSApplication.ActivationPolicy {
        self == .standardWindow ? .regular : .accessory
    }
}
