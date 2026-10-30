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
    case timeline
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
    @Published private(set) var provenance: ProcessProvenance?
    @Published private(set) var gatekeeperResult: String?
    @Published private(set) var gatekeeperRunning = false
    private var provenanceTask: Task<Void, Never>?
    private let fileFacts = ProcessFileFactsCache()
    private var launchdCache: (timestamp: Date, index: [String: LaunchdMatch])?
    /// Recent samples per application and background-process ID, bounded by `LiveMetricHistory`'s capacity.
    private(set) var recentProcessPoints: [String: [LiveProcessPoint]] = [:]

    var recentCPU: [HistoricalPoint] {
        recentMetrics.points.map { HistoricalPoint(timestamp: $0.timestamp, average: $0.cpuUsage, peak: $0.cpuUsage) }
    }
    @Published var inventoryLoading = false
    /// Inventories of all processes of one application, merged; separate from the single-process `inventory`.
    @Published private(set) var applicationInventory: ApplicationInventory?
    @Published private(set) var applicationInventoryLoading = false
    private var applicationInventoryGeneration = 0
    /// Large applications (browsers) can have thousands of processes; only the biggest are inspected.
    static let applicationInventoryProcessLimit = 40
    @Published private(set) var networkPorts: NetworkPortSnapshot?
    @Published private(set) var networkPortsLoading = false
    @Published var errorMessage: String?
    @Published private(set) var historyHealth = HistoryHealth()
    /// The newest 500 Activity Events seen this session, deduplicated by id. The database is the source for
    /// older ones; this list also covers events whose write failed.
    @Published private(set) var recentEvents: [ActivityEvent] = []
    @Published private(set) var activityDiff: ActivityDiff?
    /// True when the last What changed query failed, so the Summary strip can say so without blocking.
    @Published private(set) var activityDiffUnavailable = false
    private var scheduledInventories: [String: ProcessInventory] = [:]

    let settingsStore: SettingsStore
    let privilegedSampling: PrivilegedSamplingController?
    let history: HistoryRepository
    let historyViewModel = HistoryViewModel()
    let timelineViewModel = TimelineViewModel()
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
    private var diffTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private var panelVisible = false
    static let lastSeenDefaultsKey = "smack.activity.lastSeen"
    static let lastSeenMetadataKey = "activity.lastSeen"
    static let recentEventLimit = 500

    init(
        settingsStore: SettingsStore,
        history: HistoryRepository,
        scheduler: CollectionScheduler,
        privilegedSampling: PrivilegedSamplingController? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.settingsStore = settingsStore
        self.privilegedSampling = privilegedSampling
        storageScanModel = StorageScanModel(helper: privilegedSampling)
        self.history = history
        self.scheduler = scheduler
        self.defaults = defaults
        historyViewModel.showEvents = settingsStore.settings.showEventsOnCharts
        startupItemsModel.onInventory = { [weak self] inventory in
            guard let self else { return }
            Task { await self.recordStartup(inventory) }
        }
    }

    func setVisible(_ visible: Bool) {
        Task { await scheduler.setVisible(visible) }
        // Only a real transition counts: the launch-time hide must not overwrite the previous session's last look.
        guard visible != panelVisible else { return }
        panelVisible = visible
        if visible {
            diffTask?.cancel()
            diffTask = Task { await refreshActivityDiff() }
        } else {
            markActivitySeen()
        }
    }

    // MARK: Activity

    func receive(_ events: [ActivityEvent]) {
        let known = Set(recentEvents.map(\.id))
        let fresh = events.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        recentEvents = Array((fresh + recentEvents).sorted { $0.timestamp > $1.timestamp }.prefix(Self.recentEventLimit))
    }

    /// Persisted events newest first, merged with this session's in-memory ones in the same range. Throws when the
    /// database cannot be read; callers decide how to present that.
    func loadEvents(from start: Date, to end: Date, kinds: Set<ActivityEventKind>?, search: String, limit: Int) async throws -> [ActivityEvent] {
        let stored = try await history.events(from: start, to: end, kinds: kinds, search: search, limit: limit)
        let known = Set(stored.map(\.id))
        let pending = recentEvents.filter {
            !known.contains($0.id) && $0.timestamp >= start && $0.timestamp <= end
                && (kinds?.contains($0.kind) ?? true) && $0.matches(search: search)
        }
        guard !pending.isEmpty else { return stored }
        return Array((stored + pending).sorted { $0.timestamp > $1.timestamp }.prefix(limit))
    }

    /// For chart markers: a failed read quietly yields no markers instead of raising an alert on every reload.
    func events(from start: Date, to end: Date, kinds: Set<ActivityEventKind>?, search: String, limit: Int) async -> [ActivityEvent] {
        (try? await loadEvents(from: start, to: end, kinds: kinds, search: search, limit: limit)) ?? []
    }

    func recordStartup(_ inventory: StartupInventory) async {
        await scheduler.record(startup: inventory)
    }

    func recordVolumeMounted(path: String, name: String) {
        Task { await scheduler.recordVolumeMounted(path: path, name: name) }
    }

    func recordVolumeUnmounted(path: String) {
        Task { await scheduler.recordVolumeUnmounted(path: path) }
    }

    func recordSleep() {
        Task { await scheduler.recordSleep() }
    }

    func recordWake() {
        Task { await scheduler.recordWake() }
    }

    func recordPowerSource(charging: Bool, chargePercent: Double?) {
        Task { await scheduler.recordPowerSource(charging: charging, chargePercent: chargePercent) }
    }

    /// Records the moment the panel was hidden; the next open shows the window that ended here.
    private func markActivitySeen(at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: Self.lastSeenDefaultsKey)
        let history = history
        Task { try? await history.setMetadata(Self.lastSeenMetadataKey, value: String(date.timeIntervalSince1970)) }
    }

    private func lastSeen() async -> Date? {
        if let value = defaults.object(forKey: Self.lastSeenDefaultsKey) as? Double { return Date(timeIntervalSince1970: value) }
        // Defaults can be cleared independently of the database, which keeps a copy.
        guard let text = try? await history.metadata(Self.lastSeenMetadataKey), let value = Double(text) else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    /// Events and peaks since the user last hid the panel (the last hour on first use or after a clock change).
    func refreshActivityDiff(now: Date = Date()) async {
        let window = ActivityDiffBuilder.window(since: await lastSeen(), now: now)
        do {
            let events = try await loadEvents(from: window.start, to: window.end, kinds: nil, search: "", limit: 5_000)
            // Peaks come from SQLite as one value per metric; the builder only reads each point's peak.
            var points: [SystemMetric: [HistoricalPoint]] = [:]
            for metric in [SystemMetric.cpu, .memoryUsedBytes] {
                if let peak = try await history.peak(metric, from: window.start) {
                    points[metric] = [HistoricalPoint(timestamp: window.end, average: peak, peak: peak)]
                }
            }
            guard !Task.isCancelled else { return }
            activityDiff = ActivityDiffBuilder.build(events: events, systemPoints: points, current: processes, window: window)
            activityDiffUnavailable = false
        } catch {
            guard !Task.isCancelled else { return }
            activityDiff = nil
            activityDiffUnavailable = true
        }
    }

    func settingsChanged() {
        historyViewModel.showEvents = settingsStore.settings.showEventsOnCharts
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

    func process(pid: Int32) -> ProcessMetrics? {
        processes?.applications.lazy.flatMap(\.processes).first { $0.identity.pid == pid }
            ?? processes?.backgroundProcesses.first { $0.identity.pid == pid }
    }

    /// The process an event points at, when it is still running. Listener events carry only a PID.
    func liveProcess(for event: ActivityEvent) -> ProcessMetrics? {
        if let id = event.processID, let process = process(id: id) { return process }
        guard event.processID == nil, event.kind == .listenerOpened || event.kind == .listenerClosed || event.kind == .connectionOpened || event.kind == .connectionClosed,
              let pid = event.details["pid"].flatMap(Int32.init) else { return nil }
        // A PID can be reused since the event, so the name must still match.
        return process(pid: pid).flatMap { $0.name == event.processName ? $0 : nil }
    }

    /// Ancestry, origin and knowledge come from the snapshot at once; signature, architecture and quarantine are read
    /// on demand through a bounded cache.
    func loadProvenance(for process: ProcessMetrics) {
        provenanceTask?.cancel()
        gatekeeperResult = nil
        let all = allProcessesByPID()
        let index = launchdIndex()
        let knowledge = ProcessKnowledgeBase.shared
        provenance = ProcessProvenanceResolver.resolve(
            process: process, processes: all, launchdIndex: index, knowledge: knowledge, facts: nil, translated: nil
        )
        let path = process.executablePath
        let pid = process.identity.pid
        provenanceTask = Task {
            let facts: ProcessFileFacts?
            if let path { facts = await fileFacts.facts(for: path) } else { facts = nil }
            guard !Task.isCancelled else { return }
            provenance = ProcessProvenanceResolver.resolve(
                process: process, processes: all, launchdIndex: index, knowledge: knowledge,
                facts: facts, translated: ProcessProvenanceResolver.isTranslated(pid: pid)
            )
        }
    }

    func checkGatekeeper(path: String) {
        guard Capabilities.supportsGatekeeperCheck, !gatekeeperRunning else { return }
        gatekeeperRunning = true
        Task {
            let result = await GatekeeperCheck.assess(path: path)
            gatekeeperResult = result
            gatekeeperRunning = false
        }
    }

    private func allProcessesByPID() -> [Int32: ProcessMetrics] {
        var result: [Int32: ProcessMetrics] = [:]
        for process in (processes?.applications ?? []).flatMap(\.processes) + (processes?.backgroundProcesses ?? []) {
            result[process.identity.pid] = process
        }
        return result
    }

    /// One dictionary per startup inventory, never per process.
    private func launchdIndex() -> [String: LaunchdMatch] {
        guard let inventory = startupItemsModel.inventory else { return [:] }
        if let launchdCache, launchdCache.timestamp == inventory.timestamp { return launchdCache.index }
        let index = ProcessProvenanceResolver.launchdIndex(from: inventory)
        launchdCache = (inventory.timestamp, index)
        return index
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

    /// Inspects the application's largest processes one at a time, publishing the merged result as it grows.
    /// Run from `.task(id:)` so leaving the page cancels it. `refresh` skips scheduled inventories.
    func loadApplicationInventory(for application: ApplicationMetrics, refresh: Bool) async {
        applicationInventoryGeneration += 1
        let generation = applicationInventoryGeneration
        applicationInventory = nil
        applicationInventoryLoading = true
        defer { if generation == applicationInventoryGeneration { applicationInventoryLoading = false } }

        let selected = Array(application.processes.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(Self.applicationInventoryProcessLimit))
        var collected: [(process: ProcessRef, inventory: ProcessInventory)] = []
        for (index, process) in selected.enumerated() {
            guard !Task.isCancelled else { return }
            let inventory: ProcessInventory
            if !refresh, let cached = scheduledInventories[process.id] {
                inventory = cached
            } else {
                inventory = await scheduler.inventory(for: process)
            }
            guard !Task.isCancelled, generation == applicationInventoryGeneration else { return }
            collected.append((ProcessRef(process), inventory))
            if index % 4 == 3 || index == selected.count - 1 {
                applicationInventory = ApplicationInventory.aggregate(collected, total: application.processes.count)
            }
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
