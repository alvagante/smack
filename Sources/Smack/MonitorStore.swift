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
    case startupItems
    case history
    case settings
    case systemDetails
    case advancedSystemDetails
}

@MainActor
final class MonitorStore: ObservableObject {
    @Published var system: SystemSample?
    @Published var processes: ProcessSnapshot?
    @Published var route: AppRoute = .summary
    @Published private(set) var recentMetrics = LiveMetricHistory()
    @Published var inventory: ProcessInventory?
    /// Recent samples per application and background-process ID, bounded by `LiveMetricHistory`'s capacity.
    private(set) var recentProcessPoints: [String: [LiveProcessPoint]] = [:]

    var recentCPU: [HistoricalPoint] {
        recentMetrics.points.map { HistoricalPoint(timestamp: $0.timestamp, average: $0.cpuUsage, peak: $0.cpuUsage) }
    }
    @Published var inventoryLoading = false
    @Published private(set) var networkPorts: NetworkPortSnapshot?
    @Published private(set) var networkPortsLoading = false
    @Published var errorMessage: String?
    @Published private(set) var historyHealth = HistoryHealth()
    private var scheduledInventories: [String: ProcessInventory] = [:]

    let settingsStore: SettingsStore
    let privilegedSampling: PrivilegedSamplingController?
    let history: HistoryRepository
    let historyViewModel = HistoryViewModel()
    let resourceInsightViewModel = ResourceInsightViewModel()
    let applicationListViewModel = ApplicationListViewModel()
    let processDetailViewModel = ProcessDetailViewModel()
    let networkPortsViewModel = NetworkPortsViewModel()
    let settingsViewModel = SettingsViewModel()
    let storageScanModel: StorageScanModel
    let startupItemsModel = StartupItemsModel()
    private let scheduler: CollectionScheduler
    private var inventoryTask: Task<Void, Never>?
    private var networkPortsTask: Task<Void, Never>?

    init(
        settingsStore: SettingsStore,
        history: HistoryRepository,
        scheduler: CollectionScheduler,
        privilegedSampling: PrivilegedSamplingController? = nil
    ) {
        self.settingsStore = settingsStore
        self.privilegedSampling = privilegedSampling
        storageScanModel = StorageScanModel(helper: privilegedSampling)
        self.history = history
        self.scheduler = scheduler
    }

    func setVisible(_ visible: Bool) {
        Task { await scheduler.setVisible(visible) }
    }

    func settingsChanged() {
        Task { await scheduler.update(settings: settingsStore.settings) }
    }

    func receive(_ health: HistoryHealth) {
        guard health.revision > historyHealth.revision else { return }
        historyHealth = health
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
        guard processes.map({ snapshot.timestamp > $0.timestamp }) ?? true else { return }
        recordRecentPoints(snapshot)
        processes = snapshot
        let liveIDs = Set(snapshot.applications.flatMap(\.processes).map(\.id) + snapshot.backgroundProcesses.map(\.id))
        scheduledInventories = scheduledInventories.filter { liveIDs.contains($0.key) }
    }

    private func recordRecentPoints(_ snapshot: ProcessSnapshot) {
        var next: [String: [LiveProcessPoint]] = [:]
        func append(_ id: String, _ point: LiveProcessPoint) {
            var points = recentProcessPoints[id] ?? []
            points.append(point)
            if points.count > recentMetrics.capacity { points.removeFirst(points.count - recentMetrics.capacity) }
            next[id] = points
        }
        for application in snapshot.applications {
            append(application.id, LiveProcessPoint(
                cpuUsage: application.cpuUsage,
                memoryBytes: Double(application.memoryBytes),
                diskReadRate: application.diskReadRate,
                diskWriteRate: application.diskWriteRate
            ))
        }
        for process in snapshot.backgroundProcesses {
            append(process.id, LiveProcessPoint(
                cpuUsage: process.cpuUsage,
                memoryBytes: Double(process.memoryBytes),
                diskReadRate: process.diskReadRate,
                diskWriteRate: process.diskWriteRate
            ))
        }
        recentProcessPoints = next
    }

    func receive(_ snapshot: NetworkPortSnapshot) {
        networkPorts = snapshot
        networkPortsLoading = false
    }

    func receive(_ inventory: ProcessInventory, for id: String) {
        guard process(id: id) != nil else { return }
        scheduledInventories[id] = inventory
    }

    func loadNetworkPorts() {
        networkPortsTask?.cancel()
        networkPortsLoading = true
        networkPortsTask = Task {
            let result = await scheduler.networkPorts()
            guard !Task.isCancelled else { return }
            receive(result)
        }
    }

    func application(id: String) -> ApplicationMetrics? {
        processes?.applications.first { $0.id == id }
    }

    func process(id: String) -> ProcessMetrics? {
        processes?.applications.flatMap(\.processes).first { $0.id == id }
            ?? processes?.backgroundProcesses.first { $0.id == id }
    }

    func loadInventory(for process: ProcessMetrics) {
        inventoryTask?.cancel()
        inventory = scheduledInventories[process.id]
        inventoryLoading = true
        inventoryTask = Task {
            let result = await scheduler.inventory(for: process)
            guard !Task.isCancelled else { return }
            inventory = result
            inventoryLoading = false
        }
    }

    func systemHistory(_ metric: SystemMetric, hours: Double = 1) async -> [HistoricalPoint] {
        do {
            return try await history.systemSeries(metric, from: Date().addingTimeInterval(-hours * 3600))
        } catch {
            errorMessage = "History could not be read: \(error.localizedDescription)"
            return []
        }
    }

    /// Every metric for one instance (`processID`), or summed over all instances of `program`.
    func processHistory(program: String, processID: String?, hours: Double, limit: Int) async -> [ProcessMetric: [HistoricalPoint]] {
        do {
            return try await history.processHistory(program: program, processID: processID, from: Date().addingTimeInterval(-hours * 3600), limit: limit)
        } catch {
            errorMessage = "History could not be read: \(error.localizedDescription)"
            return [:]
        }
    }

    func historicalPrograms(hours: Double) async -> [HistoricalProgram] {
        do {
            return try await history.programs(from: Date().addingTimeInterval(-hours * 3600))
        } catch {
            errorMessage = "History could not be read: \(error.localizedDescription)"
            return []
        }
    }

    func historicalInstances(of program: String, hours: Double) async -> [HistoricalProcess] {
        do {
            return try await history.instances(named: program, from: Date().addingTimeInterval(-hours * 3600))
        } catch {
            errorMessage = "History could not be read: \(error.localizedDescription)"
            return []
        }
    }
}
