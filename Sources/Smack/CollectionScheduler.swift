import Foundation

actor CollectionScheduler {
    private let systemCollector: SystemMetricsCollecting
    private let processCollector: ProcessMetricsCollecting
    private let inventoryCollector: InventoryCollecting
    private let history: HistoryRepository
    private var settings: CollectionSettings
    private var visible = false
    private var systemTask: Task<Void, Never>?
    private var processTask: Task<Void, Never>?
    private var inventoryTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private let onSystem: @Sendable (SystemSample) -> Void
    private let onProcesses: @Sendable (ProcessSnapshot) -> Void
    private let onInventory: @Sendable (String, ProcessInventory) -> Void

    init(
        systemCollector: SystemMetricsCollecting,
        processCollector: ProcessMetricsCollecting,
        inventoryCollector: InventoryCollecting,
        history: HistoryRepository,
        settings: CollectionSettings,
        onSystem: @escaping @Sendable (SystemSample) -> Void,
        onProcesses: @escaping @Sendable (ProcessSnapshot) -> Void,
        onInventory: @escaping @Sendable (String, ProcessInventory) -> Void = { _, _ in }
    ) {
        self.systemCollector = systemCollector
        self.processCollector = processCollector
        self.inventoryCollector = inventoryCollector
        self.history = history
        self.settings = settings
        self.onSystem = onSystem
        self.onProcesses = onProcesses
        self.onInventory = onInventory
    }

    func setVisible(_ value: Bool) {
        visible = value
        restartSampling()
    }

    func update(settings: CollectionSettings) {
        self.settings = settings
        restartSampling()
    }

    func inventory(for process: ProcessMetrics) -> ProcessInventory {
        inventoryCollector.collectInventory(for: process)
    }

    private func restartSampling() {
        systemTask?.cancel()
        processTask?.cancel()
        inventoryTask?.cancel()
        systemTask = Task { await runSystemLoop() }
        processTask = Task { await runProcessLoop() }
        if maintenanceTask == nil {
            maintenanceTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.maintainHistory()
                    try? await Task.sleep(for: .seconds(300))
                }
            }
        }
        if let interval = settings.backgroundInventoryInterval {
            inventoryTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.runScheduledInventory()
                    try? await Task.sleep(for: .seconds(interval))
                }
            }
        }
    }

    private func runSystemLoop() async {
        while !Task.isCancelled {
            let sample = systemCollector.collectSystemSample()
            onSystem(sample)
            try? await history.save(system: sample)
            let interval = visible ? 1.0 : settings.backgroundSystemInterval
            guard let interval else { return }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func runProcessLoop() async {
        while !Task.isCancelled {
            let snapshot = processCollector.collectProcessSnapshot()
            onProcesses(snapshot)
            try? await history.save(processes: snapshot)
            let interval = visible ? 1.0 : settings.backgroundProcessInterval
            guard let interval else { return }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func runScheduledInventory() {
        guard !visible else { return }
        let snapshot = processCollector.collectProcessSnapshot()
        let processes = snapshot.applications.flatMap(\.processes) + snapshot.backgroundProcesses
        for process in processes {
            guard !Task.isCancelled else { return }
            onInventory(process.id, inventoryCollector.collectInventory(for: process))
        }
    }

    private func maintainHistory() async {
        try? await history.maintain(settings: settings)
    }
}
