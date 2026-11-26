import Foundation

enum ResourceKind: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    case network = "Network"
    case disk = "Disk Activity"
    case storage = "Storage"
    case battery = "Battery"
    case thermal = "Thermal State"
    var id: String { rawValue }
}

enum AppRoute: Hashable {
    case summary
    case resource(ResourceKind)
    case applications
    case application(String)
    case process(String)
    case networkPorts
    case history
    case settings
    case systemDetails
    case advancedSystemDetails
}

@MainActor
struct MonitorViewModels {
    let history = HistoryViewModel()
    let applicationList = ApplicationListViewModel()
    let processDetail = ProcessDetailViewModel()
    let networkPorts = NetworkPortsViewModel()
    let settings = SettingsViewModel()
}

struct MonitorInventoryState {
    var current: ProcessInventory?
    var isLoading = false
    var scheduled: [String: ProcessInventory] = [:]
}

struct MonitorNetworkPortsState {
    var snapshot: NetworkPortSnapshot?
    var isLoading = false
}

private struct MonitorActiveTasks {
    var inventory: Task<Void, Never>?
    var networkPorts: Task<Void, Never>?
}

@MainActor
enum MonitorHistoryReader {
    static func systemHistory(_ metric: SystemMetric, hours: Double = 1, store: MonitorStore) async -> [HistoricalPoint] {
        await read(fallback: [], store: store) {
            try await $0.systemSeries(metric, from: Date().addingTimeInterval(-hours * 3_600))
        }
    }

    /// Every metric for one instance (`processID`), or summed over all instances of `program`.
    static func processHistory(
        program: String,
        processID: String?,
        hours: Double,
        limit: Int,
        store: MonitorStore
    ) async -> [ProcessMetric: [HistoricalPoint]] {
        await read(fallback: [:], store: store) {
            try await $0.processHistory(
                program: program,
                processID: processID,
                from: Date().addingTimeInterval(-hours * 3_600),
                limit: limit
            )
        }
    }

    static func historicalPrograms(hours: Double, store: MonitorStore) async -> [HistoricalProgram] {
        await read(fallback: [], store: store) {
            try await $0.programs(from: Date().addingTimeInterval(-hours * 3_600))
        }
    }

    static func historicalInstances(of program: String, hours: Double, store: MonitorStore) async -> [HistoricalProcess] {
        await read(fallback: [], store: store) {
            try await $0.instances(named: program, from: Date().addingTimeInterval(-hours * 3_600))
        }
    }

    private static func read<T>(
        fallback: T,
        store: MonitorStore,
        operation: (HistoryRepository) async throws -> T
    ) async -> T {
        do {
            return try await operation(store.history)
        } catch {
            store.errorMessage = "History could not be read: \(error.localizedDescription)"
            return fallback
        }
    }
}

@MainActor
final class MonitorStore: ObservableObject {
    @Published var system: SystemSample?
    @Published var processes: ProcessSnapshot?
    @Published var route: AppRoute = .summary
    @Published private(set) var recentMetrics = LiveMetricHistory()
    @Published var inventoryState = MonitorInventoryState()
    @Published var networkPortsState = MonitorNetworkPortsState()
    @Published var errorMessage: String?

    let settingsStore: SettingsStore
    let privilegedSampling: PrivilegedSamplingController?
    let history: HistoryRepository
    let viewModels = MonitorViewModels()
    private let scheduler: CollectionScheduler
    private var activeTasks = MonitorActiveTasks()

    init(
        settingsStore: SettingsStore,
        history: HistoryRepository,
        scheduler: CollectionScheduler,
        privilegedSampling: PrivilegedSamplingController? = nil
    ) {
        self.settingsStore = settingsStore
        self.privilegedSampling = privilegedSampling
        self.history = history
        self.scheduler = scheduler
    }

    func setVisible(_ visible: Bool) {
        Task { await scheduler.setVisible(visible) }
    }

    func settingsChanged() {
        Task { await scheduler.update(settings: settingsStore.settings) }
        Task { try? await history.maintain(settings: settingsStore.settings) }
    }

    func receive(_ sample: SystemSample) {
        system = sample
        let memoryUsage = sample.memory.totalBytes > 0
            ? Double(sample.memory.usedBytes) / Double(sample.memory.totalBytes) * 100
            : 0
        recentMetrics.append(LiveMetricPoint(
            timestamp: sample.timestamp,
            cpuUsage: sample.cpu.totalUsage,
            memoryUsage: memoryUsage,
            receiveRate: sample.receiveRate,
            sendRate: sample.sendRate,
            diskReadRate: sample.diskReadRate,
            diskWriteRate: sample.diskWriteRate
        ))
    }

    func receive(_ snapshot: ProcessSnapshot) {
        processes = snapshot
        guard !inventoryState.scheduled.isEmpty else { return }
        var activeIDs = Set<String>()
        let estimatedCount = snapshot.backgroundProcesses.count
            + snapshot.applications.reduce(0) { $0 + $1.processes.count }
        activeIDs.reserveCapacity(estimatedCount)
        for application in snapshot.applications {
            for process in application.processes { activeIDs.insert(process.id) }
        }
        for process in snapshot.backgroundProcesses { activeIDs.insert(process.id) }
        inventoryState.scheduled = inventoryState.scheduled.filter { activeIDs.contains($0.key) }
    }

    func receive(_ snapshot: NetworkPortSnapshot) {
        networkPortsState.snapshot = snapshot
        networkPortsState.isLoading = false
    }

    func receive(_ inventory: ProcessInventory, for id: String) {
        inventoryState.scheduled[id] = inventory
    }

    func loadNetworkPorts() {
        activeTasks.networkPorts?.cancel()
        networkPortsState.isLoading = true
        activeTasks.networkPorts = Task {
            let result = await scheduler.networkPorts()
            guard !Task.isCancelled else { return }
            receive(result)
        }
    }

    func application(id: String) -> ApplicationMetrics? {
        processes?.applications.first { $0.id == id }
    }

    func process(id: String) -> ProcessMetrics? {
        if let applications = processes?.applications {
            for application in applications {
                if let match = application.processes.first(where: { $0.id == id }) {
                    return match
                }
            }
        }
        return processes?.backgroundProcesses.first { $0.id == id }
    }

    func loadInventory(for process: ProcessMetrics) {
        activeTasks.inventory?.cancel()
        inventoryState.current = inventoryState.scheduled[process.id]
        inventoryState.isLoading = true
        activeTasks.inventory = Task {
            let result = await scheduler.inventory(for: process)
            guard !Task.isCancelled else { return }
            inventoryState.current = result
            inventoryState.isLoading = false
        }
    }
}
