import Foundation

actor CollectionScheduler {
    private let systemCollector: SystemMetricsCollecting
    private let processCollector: ProcessMetricsCollecting
    private let inventoryCollector: InventoryCollecting
    private let networkPortCollector: NetworkPortCollecting
    private let history: HistoryPersistence
    private let activity: any ActivityRecording
    private var settings: CollectionSettings
    private var visible = false
    private var temperaturesWanted = false
    private var systemTask: Task<Void, Never>?
    private var processTask: Task<Void, Never>?
    private var inventoryTask: Task<Void, Never>?
    private var networkPortTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private let onSystem: @Sendable (SystemSample) -> Void
    private let onProcesses: @Sendable (ProcessSnapshot) -> Void
    private let onInventory: @Sendable (String, ProcessInventory) -> Void
    private let onNetworkPorts: @Sendable (NetworkPortSnapshot) -> Void
    private let onEvents: @Sendable ([ActivityEvent]) -> Void

    init(
        systemCollector: SystemMetricsCollecting,
        processCollector: ProcessMetricsCollecting,
        inventoryCollector: InventoryCollecting,
        networkPortCollector: NetworkPortCollecting,
        history: HistoryRepository,
        settings: CollectionSettings,
        onSystem: @escaping @Sendable (SystemSample) -> Void,
        onProcesses: @escaping @Sendable (ProcessSnapshot) -> Void,
        onInventory: @escaping @Sendable (String, ProcessInventory) -> Void = { _, _ in },
        onNetworkPorts: @escaping @Sendable (NetworkPortSnapshot) -> Void = { _ in },
        onHistoryHealth: @escaping @Sendable (HistoryHealth) -> Void = { _ in },
        activity: (any ActivityRecording)? = nil,
        onEvents: @escaping @Sendable ([ActivityEvent]) -> Void = { _ in }
    ) {
        self.systemCollector = systemCollector
        self.processCollector = processCollector
        self.inventoryCollector = inventoryCollector
        self.networkPortCollector = networkPortCollector
        self.history = HistoryPersistence(writer: history, onHealth: onHistoryHealth)
        self.activity = activity ?? ActivityRecorder(metadata: history)
        self.settings = settings
        self.onSystem = onSystem
        self.onProcesses = onProcesses
        self.onInventory = onInventory
        self.onNetworkPorts = onNetworkPorts
        self.onEvents = onEvents
    }

    func setTemperaturesWanted(_ value: Bool) {
        temperaturesWanted = value
    }

    func setVisible(_ value: Bool) {
        visible = value
        restartSampling()
    }

    func update(settings: CollectionSettings) async {
        self.settings = settings
        restartSampling()
        await maintainHistory()
    }

    func inventory(for process: ProcessMetrics) async -> ProcessInventory {
        await inventoryCollector.collectInventory(
            for: process,
            includePrivileged: settings.privilegedSampling
        )
    }

    func networkPorts() async -> NetworkPortSnapshot {
        await networkPortCollector.collectNetworkPorts(
            includePrivileged: settings.privilegedSampling
        )
    }

    private func restartSampling() {
        systemTask?.cancel()
        processTask?.cancel()
        inventoryTask?.cancel()
        networkPortTask?.cancel()
        systemTask = Task { await runSystemLoop() }
        processTask = Task { await runProcessLoop() }
        networkPortTask = Task { await runNetworkPortLoop() }
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
            let sample = systemCollector.collectSystemSample(includeTemperatures: visible && temperaturesWanted)
            onSystem(sample)
            await history.save(system: sample)
            await deliver(await activity.record(system: sample, settings: settings))
            let interval = visible ? 1.0 : settings.backgroundSystemInterval
            guard let interval else { return }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func runProcessLoop() async {
        while !Task.isCancelled {
            let started = ProcessInfo.processInfo.systemUptime
            let snapshot = await processCollector.collectProcessSnapshot(includePrivileged: settings.privilegedSampling)
            guard !Task.isCancelled else { return }
            if let snapshot {
                onProcesses(snapshot)
                if settings.recordProcessHistory {
                    await history.save(processes: snapshot.trimmedForHistory(limit: settings.processHistoryTopCount))
                }
                await deliver(await activity.record(processes: snapshot))
            }
            let interval = visible ? 1.0 : settings.backgroundProcessInterval
            guard let interval else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            try? await Task.sleep(for: .seconds(max(0.05, interval - elapsed)))
        }
    }

    private func runNetworkPortLoop() async {
        guard Capabilities.supportsNetworkPortInspection else { return }
        while !Task.isCancelled {
            let snapshot = await networkPortCollector.collectNetworkPorts(
                includePrivileged: settings.privilegedSampling
            )
            guard !Task.isCancelled else { return }
            onNetworkPorts(snapshot)
            await deliver(await activity.record(network: snapshot, settings: settings))
            let interval = visible ? 5.0 : settings.backgroundNetworkInterval
            guard let interval else { return }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func runScheduledInventory() async {
        guard !visible, !Capabilities.isSandboxed else { return }
        guard let snapshot = await processCollector.collectProcessSnapshot(includePrivileged: settings.privilegedSampling),
              !Task.isCancelled else { return }
        let processes = snapshot.applications.flatMap(\.processes) + snapshot.backgroundProcesses
        for process in processes {
            guard !Task.isCancelled else { return }
            let inventory = await inventoryCollector.collectInventory(
                for: process,
                includePrivileged: settings.privilegedSampling
            )
            guard !Task.isCancelled else { return }
            onInventory(process.id, inventory)
        }
    }

    // MARK: Activity events

    /// Persistence is attempted first and delivery follows even when the write failed, so the current session
    /// still shows the events while the health banner reports that history may be incomplete.
    /// Recorders keep tracking state even for disabled groups, so re-enabling one emits only new changes.
    private func deliver(_ events: [ActivityEvent]) async {
        let settings = settings
        let events = events.filter { settings.records($0.kind.group) }
        guard !events.isEmpty else { return }
        await history.save(events: events)
        onEvents(events)
    }

    func record(startup inventory: StartupInventory) async {
        await deliver(await activity.record(startup: inventory))
    }

    func recordVolumeMounted(path: String, name: String) async {
        await deliver([await activity.recordVolumeMounted(path: path, name: name)])
    }

    func recordVolumeUnmounted(path: String) async {
        await deliver([await activity.recordVolumeUnmounted(path: path)])
    }

    func recordSleep() async {
        await deliver([await activity.recordSleep(at: Date())])
    }

    func recordWake() async {
        await deliver([await activity.recordWake(at: Date())])
    }

    func recordPowerSource(charging: Bool, chargePercent: Double?) async {
        await deliver([await activity.recordPowerSource(charging: charging, chargePercent: chargePercent)])
    }

    private func maintainHistory() async {
        await history.maintain(settings: settings)
    }
}
