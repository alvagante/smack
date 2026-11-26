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
        application.run()
    }

    private static func diagnose() {
        for line in diagnosticLines() {
            print(line)
        }
    }

    static func diagnosticLines() -> [String] {
        let pids = ProcessSampling.allProcessIdentifiers(preferSysctl: Capabilities.isSandboxed)
        let records = ProcessSampling.records(
            restrictUsageToCurrentProcess: Capabilities.isSandboxed
        )
        let system = SystemCollector().collectSystemSample()
        let ports: NetworkPortSnapshot
        if Capabilities.supportsNetworkPortInspection {
            let sockets = ProcessSockets.collect()
            ports = NetworkPortCollector.snapshot(
                from: sockets.records,
                deniedProcessCount: sockets.deniedProcessCount
            )
        } else {
            ports = NetworkPortSnapshot(
                timestamp: Date(),
                ports: [],
                warning: "Port inspection is limited by the App Sandbox; processes owned by other users are unavailable."
            )
        }
        var lines = [
            "flavor=\(Capabilities.flavor.rawValue)",
            "sandboxed=\(Capabilities.isSandboxed)",
            "pids=\(pids.count)",
            "records=\(records.count)",
            "recordsWithUsage=\(records.count { $0.physicalFootprint > 0 })",
            "ownProcess=\(records.contains { $0.pid == getpid() })",
            "cpuCores=\(system.cpu.coreUsage.count)",
            "interfaces=\(system.interfaces.count)",
            "disks=\(system.disks.count)",
            "volumes=\(system.volumes.count)",
            "gpu=\(system.gpuName)",
            "battery=\(system.battery != nil)",
            "ports=\(ports.ports.count)"
        ]
        if let warning = ports.warning { lines.append("portsWarning=\(warning)") }
#if SMACK_APP_STORE
        lines.append("helperStatus=unavailable")
#else
        lines.append("helperMode=\(PrivilegedHelperMode(identity: .current()))")
        lines.append("helperServiceStatus=\(SMAppService.daemon(plistName: SmackIPC.daemonPlistName).status.rawValue)")
        lines.append("helperLegacyInstalled=\(LegacyHelperInstaller.isInstalled)")
#endif
        return lines
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: PanelController?
    private var store: MonitorStore?
    private var scheduler: CollectionScheduler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let history = try HistoryRepository(databaseURL: Self.historyDatabaseURL())
            let settingsStore = SettingsStore()
            let privilegedClient = PrivilegedSamplingClient()
            let privilegedController = Capabilities.supportsPrivilegedSampling
                ? PrivilegedSamplingController(client: privilegedClient)
                : nil
            let scheduler = makeScheduler(history: history, settings: settingsStore.settings, privilegedClient: privilegedClient)
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

    static func historyDatabaseURL(in baseDirectory: URL? = nil) throws -> URL {
        let support: URL
        if let baseDirectory {
            support = baseDirectory
        } else {
            support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        }
        let directory = support.appendingPathComponent("Smack", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.sqlite3")
    }

    func makeScheduler(
        history: HistoryRepository,
        settings: CollectionSettings,
        privilegedClient: PrivilegedSamplingClient
    ) -> CollectionScheduler {
        CollectionScheduler(
            systemCollector: SystemCollector(),
            processCollector: ProcessSnapshotService(local: ProcessCollector(), privileged: privilegedClient),
            inventoryCollector: InventoryCollector(privileged: privilegedClient),
            networkPortCollector: NetworkPortCollector(privileged: privilegedClient),
            history: history,
            settings: settings,
            onSystem: { [weak self] sample in Task { @MainActor in self?.store?.receive(sample) } },
            onProcesses: { [weak self] snapshot in Task { @MainActor in self?.store?.receive(snapshot) } },
            onInventory: { [weak self] id, inventory in Task { @MainActor in self?.store?.receive(inventory, for: id) } },
            onNetworkPorts: { [weak self] snapshot in Task { @MainActor in self?.store?.receive(snapshot) } }
        )
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

    func applicationWillTerminate(_ notification: Notification) {
        store?.setVisible(false)
    }
}
