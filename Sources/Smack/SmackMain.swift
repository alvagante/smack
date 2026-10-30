import AppKit
import Darwin
import ServiceManagement
import SmackIPC
import SwiftUI

@main
@MainActor
enum SmackMain {
    static func main() {
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: PanelController?
    private var store: MonitorStore?
    private var scheduler: CollectionScheduler?
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
                }
            )
            let store = MonitorStore(
                settingsStore: settingsStore,
                history: history,
                scheduler: scheduler,
                privilegedSampling: privilegedController
            )
            self.store = store
            self.scheduler = scheduler
            privilegedController?.prepare(enabled: settingsStore.settings.privilegedSampling)
            configureStatusItem()
            let nativeMenuBarStore = NativeMenuBarStore()
            panelController = PanelController(store: store, nativeMenuBarStore: nativeMenuBarStore, statusItem: statusItem)
            store.setVisible(false)
            if CommandLine.arguments.contains("--open-panel") {
                panelController?.togglePinned()
            }
        } catch {
            NSAlert(error: error).runModal()
            NSApplication.shared.terminate(nil)
        }
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Smack system monitor")
        statusItem.button?.toolTip = "Open Smack"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
    }

    @objc private func statusItemClicked() {
        panelController?.togglePinned()
    }

    /// Handles application termination by hiding the monitor panel and ensuring that all pending
    /// preference updates in `UserDefaults` are synchronously committed to disk before process exit.
    /// - Parameter notification: The termination notification posted by `NSApplication`.
    func applicationWillTerminate(_ notification: Notification) {
        store?.setVisible(false)
        _ = UserDefaults.standard.synchronize()
        didSynchronizeOnTeardown = true
    }
}
