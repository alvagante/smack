import Foundation

private struct CollectionProviders {
    let system: SystemMetricsCollecting
    let process: ProcessMetricsCollecting
    let inventory: InventoryCollecting
    let networkPort: NetworkPortCollecting
}

private struct CollectionCallbacks {
    let onSystem: @Sendable (SystemSample) -> Void
    let onProcesses: @Sendable (ProcessSnapshot) -> Void
    let onInventory: @Sendable (String, ProcessInventory) -> Void
    let onNetworkPorts: @Sendable (NetworkPortSnapshot) -> Void
}

private struct SchedulerTasks {
    var system: Task<Void, Never>?
    var process: Task<Void, Never>?
    var inventory: Task<Void, Never>?
    var networkPort: Task<Void, Never>?
    var maintenance: Task<Void, Never>?

    mutating func cancelSampling() {
        system?.cancel()
        process?.cancel()
        inventory?.cancel()
        networkPort?.cancel()
    }
}

actor CollectionScheduler {
    private let providers: CollectionProviders
    private let callbacks: CollectionCallbacks
    private let history: HistoryRepository
    private var settings: CollectionSettings
    private var visible = false
    private var tasks = SchedulerTasks()

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
        onNetworkPorts: @escaping @Sendable (NetworkPortSnapshot) -> Void = { _ in }
    ) {
        providers = CollectionProviders(
            system: systemCollector,
            process: processCollector,
            inventory: inventoryCollector,
            networkPort: networkPortCollector
        )
        callbacks = CollectionCallbacks(
            onSystem: onSystem,
            onProcesses: onProcesses,
            onInventory: onInventory,
            onNetworkPorts: onNetworkPorts
        )
        self.history = history
        self.settings = settings
    }

    func setVisible(_ value: Bool) {
        visible = value
        restartSampling()
    }

    func update(settings: CollectionSettings) {
        self.settings = settings
        restartSampling()
    }

    func inventory(for process: ProcessMetrics) async -> ProcessInventory {
        await providers.inventory.collectInventory(
            for: process,
            includePrivileged: settings.privilegedSampling
        )
    }

    func networkPorts() async -> NetworkPortSnapshot {
        await providers.networkPort.collectNetworkPorts(
            includePrivileged: settings.privilegedSampling
        )
    }

    private func restartSampling() {
        tasks.cancelSampling()
        tasks.system = Task { await runSystemLoop() }
        tasks.process = Task { await runProcessLoop() }
        tasks.networkPort = Task { await runNetworkPortLoop() }
        startMaintenanceIfNeeded()
        startInventoryIfEnabled()
    }

    private func startMaintenanceIfNeeded() {
        guard tasks.maintenance == nil else { return }
        tasks.maintenance = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.maintainHistory()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func startInventoryIfEnabled() {
        guard let interval = settings.backgroundInventoryInterval else { return }
        tasks.inventory = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runScheduledInventory()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func runSystemLoop() async {
        while !Task.isCancelled {
            let sample = providers.system.collectSystemSample()
            callbacks.onSystem(sample)
            try? await history.save(system: sample)
            let interval = visible ? 1.0 : settings.backgroundSystemInterval
            guard let interval else { return }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func runProcessLoop() async {
        while !Task.isCancelled {
            let snapshot = await providers.process.collectProcessSnapshot(includePrivileged: settings.privilegedSampling)
            callbacks.onProcesses(snapshot)
            try? await history.save(processes: snapshot)
            let interval = visible ? 1.0 : settings.backgroundProcessInterval
            guard let interval else { return }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func runNetworkPortLoop() async {
        guard Capabilities.supportsNetworkPortInspection else { return }
        while !Task.isCancelled {
            let snapshot = await providers.networkPort.collectNetworkPorts(
                includePrivileged: settings.privilegedSampling
            )
            callbacks.onNetworkPorts(snapshot)
            try? await Task.sleep(for: .seconds(visible ? 5 : 60))
        }
    }

    private func runScheduledInventory() async {
        guard !visible, !Capabilities.isSandboxed else { return }
        let snapshot = await providers.process.collectProcessSnapshot(includePrivileged: settings.privilegedSampling)
        let processes = snapshot.applications.flatMap(\.processes) + snapshot.backgroundProcesses
        for process in processes {
            guard !Task.isCancelled else { return }
            let inventory = await providers.inventory.collectInventory(
                for: process,
                includePrivileged: settings.privilegedSampling
            )
            callbacks.onInventory(process.id, inventory)
        }
    }

    private func maintainHistory() async {
        try? await history.maintain(settings: settings)
    }
}
