import AppKit
import SwiftUI

@main
@MainActor
enum SmackMain {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
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
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("Smack", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite3"))
            let settingsStore = SettingsStore()
            let scheduler = CollectionScheduler(
                systemCollector: SystemCollector(),
                processCollector: ProcessCollector(),
                inventoryCollector: InventoryCollector(),
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
                }
            )
            let store = MonitorStore(settingsStore: settingsStore, history: history, scheduler: scheduler)
            self.store = store
            self.scheduler = scheduler
            configureStatusItem()
            panelController = PanelController(store: store, statusItem: statusItem)
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

    func applicationWillTerminate(_ notification: Notification) {
        store?.setVisible(false)
    }
}
