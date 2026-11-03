import AppKit
import Combine
import UserNotifications
import Darwin
import ServiceManagement
import SmackIPC
import SwiftUI

@main
@MainActor
enum SmackMain {
    static func main() {
        if CommandLine.arguments == [CommandLine.arguments[0], "--baseline-section"] {
            Task.detached { exit(await BaselineWorker.run()) }
            dispatchMain()
        }
#if !SMACK_APP_STORE
        if CommandLine.arguments == [CommandLine.arguments[0], "--diagnose-helper"] {
            Task.detached {
                let client = PrivilegedSamplingClient()
                client.setAvailable(true)
                let snapshot = await client.collectSnapshot()
                let version = await client.protocolVersion()
                let btm = await client.dumpBackgroundTasks()
                let profiles = await client.listConfigurationProfiles()
                client.setAvailable(false)
                print("snapshotAvailable=\(snapshot != nil) helperProtocol=\(version) btmBytes=\(btm?.utf8.count ?? 0) profilesBytes=\(profiles?.utf8.count ?? 0)")
                exit(0)
            }
            dispatchMain()
        }
#endif
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--signature-metadata" {
            let info = ProcessProvenanceResolver.signature(path: CommandLine.arguments[2])
            if let data = try? JSONEncoder().encode(info) { FileHandle.standardOutput.write(data) }
            exit(0)
        }
        if CommandLine.arguments.contains("--diagnose") {
            diagnose()
            exit(0)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        delegate.configureMainMenu()
        application.run()
    }

    private static func diagnose() {
        let pids = ProcessSampling.allProcessIdentifiers()
        let records = ProcessSampling.records(
            restrictUsageToCurrentProcess: Capabilities.isSandboxed
        )
        let system = SystemCollector().collectSystemSample()
        let sockets = ProcessSockets.collect()
        let ports = NetworkPortCollector.snapshot(
            from: sockets.records,
            deniedProcessCount: sockets.deniedProcessCount
        )
        print("flavor=\(Capabilities.flavor.rawValue)")
        print("sandboxed=\(Capabilities.isSandboxed)")
        print("pids=\(pids.count)")
        print("records=\(records.count)")
        print("recordsWithUsage=\(records.count { $0.physicalFootprint > 0 })")
        print("ownProcess=\(records.contains { $0.pid == getpid() })")
        print("cpuCores=\(system.cpu.coreUsage.count)")
        print("interfaces=\(system.interfaces.count)")
        print("disks=\(system.disks.count)")
        print("volumes=\(system.volumes.count)")
        print("gpu=\(system.gpuName)")
        print("gpuUtilization=\(system.gpu.utilizationPercent.map { String($0) } ?? "unavailable")")
        print("memoryPressure=\(system.memory.pressure.rawValue)")
        print("swapUsed=\(system.memory.swapUsedBytes) swapTotal=\(system.memory.swapTotalBytes)")
        print("battery=\(system.battery != nil)")
        print("ports=\(ports.ports.count)")
        if let warning = ports.warning { print("portsWarning=\(warning)") }
#if SMACK_APP_STORE
        print("helperStatus=unavailable")
#else
        print("helperMode=\(PrivilegedHelperMode(identity: .current()))")
        print("helperServiceStatus=\(SMAppService.daemon(plistName: SmackIPC.daemonPlistName).status.rawValue)")
        print("helperLegacyInstalled=\(LegacyHelperInstaller.isInstalled)")
#endif
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
#if !SMACK_APP_STORE
    private var controlServer: ControlServer?
    private var controlSettingsObservation: AnyCancellable?
#endif
    private var pendingNavigationURL: URL?
    private var statusItem: NSStatusItem!
    private var panelController: PanelController?
    private var store: MonitorStore?
    private var scheduler: CollectionScheduler?
    private var activityObservers: ActivitySystemObservers?
    private let terminateApplication: () -> Void
    private(set) var didSynchronizeOnTeardown = false

    init(terminateApplication: @escaping () -> Void = { NSApplication.shared.terminate(nil) }) {
        self.terminateApplication = terminateApplication
    }

    func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(
            title: "Quit Smack",
            action: #selector(requestQuit(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApplication.shared.mainMenu = mainMenu
    }

    @objc func requestQuit(_ sender: Any?) {
        terminateApplication()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("Smack", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite3"))
            let settingsStore = SettingsStore()
            let privilegedClient = PrivilegedSamplingClient()
            let privilegedController = Capabilities.supportsPrivilegedSampling
                ? PrivilegedSamplingController(client: privilegedClient)
                : nil
            let dispatcher = AlertDispatcher(notifier: SystemUserNotifier(), defaults: .standard)
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(
                identifier: "SMACK_ALERT", actions: [
                    UNNotificationAction(identifier: "OPEN", title: "Open", options: .foreground),
                    UNNotificationAction(identifier: "SNOOZE", title: "Snooze 1 h"),
                    UNNotificationAction(identifier: "MUTE", title: "Mute")
                ], intentIdentifiers: [])])
            let scheduler = CollectionScheduler(
                systemCollector: SystemCollector(),
                processCollector: ProcessSnapshotService(
                    local: ProcessCollector(),
                    privileged: privilegedClient
                ),
                inventoryCollector: InventoryCollector(privileged: privilegedClient),
                networkPortCollector: NetworkPortCollector(privileged: privilegedClient),
                history: history,
                settings: settingsStore.settings,
                onSystem: { [weak self] sample in
                    Task { @MainActor in self?.store?.receive(sample) }
                },
                onProcesses: { [weak self] snapshot in
                    Task { @MainActor in self?.store?.receive(snapshot) }
                },
                onInventory: { [weak self] id, inventory in
                    Task { @MainActor in self?.store?.receive(inventory, for: id) }
                },
                onNetworkPorts: { [weak self] snapshot in
                    Task { @MainActor in self?.store?.receive(snapshot) }
                },
                onHistoryHealth: { [weak self] health in
                    Task { @MainActor in self?.store?.receive(health) }
                },
                onEvents: { [weak self] events in
                    Task { @MainActor in self?.store?.receive(events) }
                },
                onPosture: { [weak self] snapshot in
                    Task { @MainActor in self?.store?.receive(snapshot) }
                },
                onStartup: { [weak self] inventory in
                    Task { @MainActor in self?.store?.receive(inventory) }
                },
                helper: privilegedClient,
                onAlert: { await dispatcher.dispatch($0) },
                onWake: { await dispatcher.noteWake(at: $0) }
            )
            let store = MonitorStore(
                settingsStore: settingsStore,
                history: history,
                scheduler: scheduler,
                privilegedSampling: privilegedController
            )
            store.alertDispatcher = dispatcher
            dispatcher.isTargetVisible = { [weak store] in store?.alertTargetVisible($0) ?? false }
            dispatcher.isRuleEnabled = { [weak store] id in store?.alertRules.rules.contains { $0.id == id && $0.enabled } ?? false }
            _ = store.alertRules
            self.store = store
            store.startSecurityMonitoring()
            self.scheduler = scheduler
            AutomationSnapshot.startedAt = Date()
            AutomationSnapshot.store = store
            AutomationSnapshot.openURL = { [weak self] in self?.openNavigationURL($0) }
#if !SMACK_APP_STORE
            observeControlSocket(settingsStore)
#endif
            privilegedController?.prepare(enabled: settingsStore.settings.sampling.privilegedSampling)
            installActivityObservers(store: store)
            configureStatusItem()
            let nativeMenuBarStore = NativeMenuBarStore()
            panelController = PanelController(store: store, nativeMenuBarStore: nativeMenuBarStore, statusItem: statusItem)
            store.setVisible(false)
            if let url = pendingNavigationURL {
                pendingNavigationURL = nil
                openNavigationURL(url)
            } else if CommandLine.arguments.contains("--open-panel") {
                panelController?.togglePinned()
            }
        } catch {
            NSAlert(error: error).runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.last { openNavigationURL(url) }
    }

    func openNavigationURL(_ url: URL) {
        guard let store, let panelController else {
            pendingNavigationURL = url
            return
        }
        guard store.settingsStore.settings.automation.urlNavigationEnabled else { return }
        store.navigate(to: url)
        panelController.showPinned()
    }

    /// Mounts, sleep, wake and power source changes arrive as notifications; the store forwards them to the recorder.
    private func installActivityObservers(store: MonitorStore) {
        let observers = ActivitySystemObservers(handlers: .init(
            volumeMounted: { path, name in Task { @MainActor in store.recordVolumeMounted(path: path, name: name) } },
            volumeUnmounted: { path in Task { @MainActor in store.recordVolumeUnmounted(path: path) } },
            sleep: { Task { @MainActor in store.recordSleep() } },
            wake: { Task { @MainActor in store.recordWake() } },
            powerSource: { charging, percent in Task { @MainActor in store.recordPowerSource(charging: charging, chargePercent: percent) } }
        ))
        observers.install()
        activityObservers = observers
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Smack system monitor")
        statusItem.button?.toolTip = "Open Smack"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = statusItem.button {
            let menu = NSMenu()
            for (title, action) in [("Pause alerts 1 h", #selector(pauseAlerts)), ("Pause until tomorrow", #selector(pauseAlertsTomorrow)), ("Pause indefinitely", #selector(pauseAlertsIndefinitely)), ("Resume alerts", #selector(resumeAlerts))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
            return
        }
        panelController?.togglePinned()
    }

    @objc private func pauseAlerts() { store?.alertDispatcher?.pausedUntil = Date().addingTimeInterval(3600) }
    @objc private func pauseAlertsTomorrow() { store?.alertDispatcher?.pausedUntil = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) }
    @objc private func pauseAlertsIndefinitely() { store?.alertDispatcher?.pausedUntil = .distantFuture }
    @objc private func resumeAlerts() { store?.alertDispatcher?.pausedUntil = nil }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let id = (response.notification.request.content.userInfo["ruleID"] as? String).flatMap(UUID.init(uuidString:))
        let action = response.actionIdentifier
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            guard let self, let store = self.store, let id,
                  let rule = store.alertRules.rules.first(where: { $0.id == id }) else { return }
            switch action {
            case "SNOOZE": store.alertRules.update { rules in
                if let i = rules.firstIndex(where: { $0.id == id }) { rules[i].snoozedUntil = Date().addingTimeInterval(3600) }
            }
            case "MUTE": store.alertRules.update { rules in
                if let i = rules.firstIndex(where: { $0.id == id }) { rules[i].enabled = false }
            }
            case "OPEN", UNNotificationDefaultActionIdentifier:
                self.openNavigationURL(rule.target?.url ?? URL(string: "smack://timeline")!)
            default: break
            }
        }
    }

#if !SMACK_APP_STORE
    func observeControlSocket(_ settings: SettingsStore, paths: [String] = ControlSocket.paths()) {
        controlSettingsObservation = settings.$settings.map(\.automation.controlSocketEnabled).removeDuplicates()
            .sink { [weak self] enabled in self?.setControlSocket(enabled: enabled, paths: paths) }
    }

    private func setControlSocket(enabled: Bool, paths: [String]) {
        guard enabled else {
            controlServer?.stop()
            controlServer = nil
            return
        }
        guard controlServer == nil else { return }
        do {
            controlServer = try ControlServer(paths: paths,
                stream: { request in await AutomationSnapshot.follow(request) }) { request in
                await AutomationSnapshot.query(request)
            }
        } catch {
            store?.errorMessage = "Control socket unavailable: \(error.localizedDescription)"
        }
    }
#endif

    /// Handles application termination by hiding the monitor panel and ensuring that all pending
    /// preference updates in `UserDefaults` are synchronously committed to disk before process exit.
    /// - Parameter notification: The termination notification posted by `NSApplication`.
    func applicationWillTerminate(_ notification: Notification) {
        store?.stopSecurityMonitoring()
#if !SMACK_APP_STORE
        controlSettingsObservation = nil
        controlServer?.stop()
        controlServer = nil
#endif
        activityObservers?.remove()
        store?.setVisible(false)
        _ = UserDefaults.standard.synchronize()
        didSynchronizeOnTeardown = true
    }
}
