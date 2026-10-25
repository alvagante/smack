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
    case history
    case settings
    case systemDetails
}

@MainActor
final class MonitorStore: ObservableObject {
    @Published var system: SystemSample?
    @Published var processes: ProcessSnapshot?
    @Published var route: AppRoute = .summary
    @Published var recentCPU: [HistoricalPoint] = []
    @Published var inventory: ProcessInventory?
    @Published var inventoryLoading = false
    @Published var errorMessage: String?
    private var scheduledInventories: [String: ProcessInventory] = [:]

    let settingsStore: SettingsStore
    let history: HistoryRepository
    let historyViewModel = HistoryViewModel()
    let applicationListViewModel = ApplicationListViewModel()
    let processDetailViewModel = ProcessDetailViewModel()
    let settingsViewModel = SettingsViewModel()
    private let scheduler: CollectionScheduler
    private var inventoryTask: Task<Void, Never>?

    init(settingsStore: SettingsStore, history: HistoryRepository, scheduler: CollectionScheduler) {
        self.settingsStore = settingsStore
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
        recentCPU.append(HistoricalPoint(timestamp: sample.timestamp, average: sample.cpu.totalUsage, peak: sample.cpu.totalUsage))
        if recentCPU.count > 60 { recentCPU.removeFirst(recentCPU.count - 60) }
    }

    func receive(_ snapshot: ProcessSnapshot) {
        processes = snapshot
    }

    func receive(_ inventory: ProcessInventory, for id: String) {
        scheduledInventories[id] = inventory
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

    func processHistory(processID: String, metric: ProcessMetric, hours: Double = 1) async -> [HistoricalPoint] {
        do {
            return try await history.processSeries(processID: processID, metric: metric, from: Date().addingTimeInterval(-hours * 3600))
        } catch {
            errorMessage = "History could not be read: \(error.localizedDescription)"
            return []
        }
    }
}
