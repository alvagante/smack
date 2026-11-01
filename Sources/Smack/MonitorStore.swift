import Combine
import Foundation

enum ResourceKind: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    case network = "Network"
    case disk = "Disk Activity"
    case gpu = "GPU"
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
    case devServers
    case docker
    case homebrew
    case devEnvironments
    case userHome
    case agents
    case installedApps
    case startupItems
    case timeline
    case history
    case settings
    case systemDetails
    case security
    case baseline
    case unavailable(String)
}

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var posture: PostureSnapshot?
    func receive(_ snapshot: PostureSnapshot) { posture = snapshot }
    func receive(_ inventory: StartupInventory) { startupItemsModel.receiveCached(inventory) }
    @Published var system: SystemSample?
    @Published var processes: ProcessSnapshot?
    @Published var route: AppRoute = .summary {
        didSet {
            guard route != oldValue else { return }
            updateDevServerVisibility()
            if route != .applications { navigationFilters.banner = nil }
            if route == .summary {
                routeHistory.removeAll()
            } else if !isNavigatingBack {
                routeHistory.append(oldValue)
            }
        }
    }
    @Published private var routeHistory: [AppRoute] = []
    private var isNavigatingBack = false
    var previousRoute: AppRoute? { routeHistory.last }
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
    /// Live GPU percent per application and background-process ID while the GPU page is open; never stored.
    private(set) var recentGPUPoints: [String: [HistoricalPoint]] = [:]

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
    @Published private(set) var devServers: [DevServer]?
    private let devServerCollector = DevServerCollector()
    private var dockerObservation: AnyCancellable?
    private var devServerTask: Task<Void, Never>?
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

    lazy var alertRules: AlertRuleStore = makeAlertRuleStore()
    private func makeAlertRuleStore() -> AlertRuleStore {
        AlertRuleStore(fileURL: nil, onChange: { [weak self] rules in
            guard let self else { return }
            Task {
                await self.scheduler.update(rules: rules)
                await self.alertDispatcher?.prepare(rules: rules)
            }
        })
    }
    var alertDispatcher: AlertDispatcher? {
        didSet { alertDispatcher?.enabled = settingsStore.settings.alertsEnabled }
    }
    func alertRuntime() async -> [UUID: AlertRuntime] { await scheduler.alertRuntime() }
    func alertTargetVisible(_ target: AlertTarget?) -> Bool {
        guard panelVisible, let target else { return false }
        let link = resolveDeepLink(target.url)
        guard link.route == route else { return false }
        switch route {
        case .networkPorts:
            return link.filters.port == networkPortsViewModel.port && networkPortsViewModel.query.isEmpty
        case .applications: return link.filters.search == applicationListViewModel.query
        case .timeline:
            return link.filters.search == timelineViewModel.query && link.filters.timelineKinds == timelineViewModel.selectedKinds
                && (link.filters.timelineInterval == nil || link.filters.timelineInterval == timelineViewModel.window().duration)
        case .settings: return link.filters.settingsPane == nil || link.filters.settingsPane == settingsViewModel.pane
        default: return true
        }
    }

    @Published private(set) var navigationFilters = ViewFilters()

    func resolveDeepLink(_ url: URL) -> DeepLink {
        var link = DeepLinkParser.parse(url, resolveProcess: { self.process(pid: $0)?.id },
            resolveApplication: { bundle in self.processes?.applications.first { $0.bundleIdentifier == bundle }?.id })
        if link.route == .networkPorts, let port = link.filters.port,
           devServers?.contains(where: { $0.ports.contains(where: { $0.port == port }) }) == true {
            link.route = .devServers
        }
        return link
    }

    func navigate(to url: URL, now: Date = Date()) {
        let link = resolveDeepLink(url)
        navigationFilters = link.filters
        if link.route == .applications { applicationListViewModel.query = link.filters.search }
        if link.route == .networkPorts {
            networkPortsViewModel.query = ""
            networkPortsViewModel.port = link.filters.port
            networkPortsViewModel.mode = .listening
        }
        if link.route == .timeline {
            timelineViewModel.select(range: .hour1)
            if let interval = link.filters.timelineInterval {
                timelineViewModel.open(window: DateInterval(start: now.addingTimeInterval(-interval), end: now))
            }
            timelineViewModel.query = link.filters.search
            timelineViewModel.selectedKinds = link.filters.timelineKinds
        }
        if let pane = link.filters.settingsPane { settingsViewModel.pane = pane }
        route = link.route
    }

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
    let dockerModel = DockerMonitor()
    let homebrewModel = HomebrewMonitor()
    let devEnvironmentModel = DevEnvironmentMonitor()
    let userHomeModel = UserHomeMonitor()
    let agentsModel = AgentMonitor()
    let installedAppsModel = InstalledAppsMonitor()
    let baselines = BaselineModel()
    func captureBaseline(name: String, sections: [String]? = nil) async throws -> BaselineDocument {
        let settings = settingsStore.settings
        let ids = sections ?? BaselineDiff.rules.keys.sorted()
        async let profiles = ids.contains("profiles") ? scheduler.baselineProfiles() : nil
        async let btm = ids.contains("startup") ? scheduler.baselineBackgroundTasks() : nil
        let (profileValue, btmValue) = await (profiles, btm)
        return try await BaselineCapture.capture(collectors: ids.map {
            MachineBaselineCollector(id: $0, settings: settings, listeners: networkPorts, profiles: profileValue, backgroundTasks: btmValue)
        }, name: name, progress: { [weak self] id, section in
            await MainActor.run { self?.baselines.progress[id] = section.status.rawValue }
        })
    }
    private let scheduler: CollectionScheduler
    private var inventoryTask: Task<Void, Never>?
    private var networkPortsTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private var panelVisible = false
    private var settingsObservation: AnyCancellable?
    private var appliedPages: Set<SummaryPage> = []
    private var securityMonitoringStarted = false
    private var enrichmentEnabled: Bool?
    private var persistenceWatcher: PersistenceWatcher?
    func stopSecurityMonitoring() {
        securityMonitoringStarted = false
        persistenceWatcher?.stop()
        Task { await scheduler.stop() }
    }
    func startSecurityMonitoring() {
        securityMonitoringStarted = true
        Task { await scheduler.restoreSecurityCache() }
        if persistenceWatcher == nil {
            let scheduler = scheduler
            persistenceWatcher = PersistenceWatcher { hourly in await scheduler.scanPersistence(hourly: hourly) }
        }
        applyEnvironmentSettings(settingsStore.settings)
    }
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
        devEnvironmentModel.onFoldersChanged = { [weak settingsStore] folders in
            settingsStore?.update { $0.devProjectFolders = folders }
        }
        dockerObservation = dockerModel.$snapshot.dropFirst().sink { [weak self] _ in
            // Published delivers before assignment; read the new snapshot on the next actor turn.
            Task { @MainActor [weak self] in self?.refreshDevServers() }
        }
        applyEnvironmentSettings(settingsStore.settings)
        // Every writer goes through SettingsStore, including ones that skip settingsChanged(), so observe it here.
        settingsObservation = settingsStore.$settings.dropFirst().sink { [weak self] settings in
            self?.applyEnvironmentSettings(settings)
        }
    }

    /// "Off" when the user turned per-process network rates off; "Unavailable" is for values the system withholds.
    var networkRateFallback: String {
        settingsStore.settings.processNetworkRateEnabled ? "Unavailable" : "Off"
    }

    /// Pushes settings that do not affect sampling to the page monitors, at launch and on every change.
    private func applyEnvironmentSettings(_ settings: CollectionSettings) {
        let enableAlerts = settings.alertsEnabled && alertDispatcher?.enabled == false
        alertDispatcher?.enabled = settings.alertsEnabled
        if enableAlerts { Task { await alertDispatcher?.prepare(rules: alertRules.rules) } }
        if securityMonitoringStarted {
            Task { await scheduler.updateFeatureSettings(settings) }
            if enrichmentEnabled != settings.persistenceEnrichmentEnabled { persistenceWatcher?.stop() }
            enrichmentEnabled = settings.persistenceEnrichmentEnabled
            if settings.watchPersistence { persistenceWatcher?.start(pollInterval: settings.persistencePollInterval) }
            else { persistenceWatcher?.stop() }
        }
        dockerModel.configure(refreshSeconds: settings.dockerRefreshSeconds, liveStats: settings.dockerLiveStats, cache: settings.inventoryCache)
        homebrewModel.cache = settings.inventoryCache
        devEnvironmentModel.configure(folders: settings.devProjectFolders, depth: settings.devScanDepth, cache: settings.inventoryCache)
        agentsModel.configure(excluded: settings.excludedAgents, customFolders: settings.customAgentFolders, cache: settings.inventoryCache)
        let shown = Set(SummaryPage.allCases.filter(settings.shows))
        let changed = shown.symmetricDifference(appliedPages)
        appliedPages = shown
        // Only pages whose state changed: re-showing an unchanged one would cancel its in-flight discovery.
        if panelVisible, !changed.isEmpty { setPageMonitorsVisible(true, only: changed) }
        updateDevServerVisibility()
    }

    /// Hidden pages skip discovery; hiding one while the panel is open stops its refresh loop.
    private func setPageMonitorsVisible(_ visible: Bool, only pages: Set<SummaryPage> = Set(SummaryPage.allCases)) {
        func show(_ page: SummaryPage) -> Bool { visible && appliedPages.contains(page) }
        if pages.contains(.docker) { dockerModel.setVisible(show(.docker) || devServersWanted) }
        if pages.contains(.homebrew) { homebrewModel.setVisible(show(.homebrew)) }
        if pages.contains(.devEnvironments) { devEnvironmentModel.setVisible(show(.devEnvironments)) }
        if pages.contains(.agents) { agentsModel.setVisible(show(.agents)) }
        if pages.contains(.installedApps) { installedAppsModel.setVisible(show(.installedApps)) }
    }

    func goBack() {
        guard let previous = routeHistory.popLast() else { return }
        isNavigatingBack = true
        defer { isNavigatingBack = false }
        route = previous
    }

    /// Pages showing temperatures or fans (Thermal State, CPU) ask for sensor readings while on screen; every
    /// `true` must be balanced by one `false`.
    func setTemperaturesWanted(_ wanted: Bool) {
        Task { await scheduler.setTemperaturesWanted(wanted) }
    }

    /// The GPU page asks for per-process GPU time while it is on screen; balance every `true` with one `false`.
    func setGPUProcessesWanted(_ wanted: Bool) {
        Task { await scheduler.setGPUProcessesWanted(wanted) }
    }

    func setVisible(_ visible: Bool) {
        Task { await scheduler.setVisible(visible) }
        // Only a real transition counts: the launch-time hide must not overwrite the previous session's last look.
        guard visible != panelVisible else { return }
        panelVisible = visible
        setPageMonitorsVisible(visible)
        updateDevServerVisibility()
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
        AutomationSnapshot.publish(fresh, from: self)
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
        // Samples carry GPU clients only while a GPU page is open; once they stop, the live window is dropped.
        if let gpu = sample.gpuProcesses {
            recordGPUPoints(gpu, at: sample.timestamp)
        } else if !recentGPUPoints.isEmpty {
            recentGPUPoints = [:]
        }
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
            diskWriteRate: sample.diskWriteRate,
            swapUsedBytes: Double(sample.memory.swapUsedBytes),
            gpuUsage: sample.gpu.utilizationPercent,
            gpuRendererUsage: sample.gpu.rendererUtilizationPercent,
            gpuTilerUsage: sample.gpu.tilerUtilizationPercent,
            memoryPressure: sample.memory.pressure.historyValue
        ))
    }

    func receive(_ snapshot: ProcessSnapshot) {
        guard processes.map({ snapshot.timestamp > $0.timestamp }) ?? true else { return }
        recordRecentPoints(snapshot)
        processes = snapshot
        agentsModel.sessions = snapshot.agentSessions
        if devServers == nil { refreshDevServers() }
        let liveIDs = Set(snapshot.applications.flatMap(\.processes).map(\.id) + snapshot.backgroundProcesses.map(\.id))
        scheduledInventories = scheduledInventories.filter { liveIDs.contains($0.key) }
    }

    /// Appends in place through the dictionary's modify accessor: copying each array out and back would duplicate
    /// every buffer on every tick, hundreds of processes times the window.
    private func recordRecentPoints(_ snapshot: ProcessSnapshot) {
        let capacity = recentMetrics.capacity
        var seen = Set<String>()
        seen.reserveCapacity(snapshot.applications.count + snapshot.backgroundProcesses.count)
        func append(_ id: String, _ point: LiveProcessPoint) {
            seen.insert(id)
            recentProcessPoints[id, default: []].append(point)
            let excess = recentProcessPoints[id, default: []].count - capacity
            if excess > 0 { recentProcessPoints[id, default: []].removeFirst(excess) }
        }
        for application in snapshot.applications {
            append(application.id, LiveProcessPoint(
                timestamp: snapshot.timestamp,
                networkThroughput: application.networkThroughput,
                cpuUsage: application.cpuUsage,
                memoryBytes: Double(application.memoryBytes),
                diskReadRate: application.diskReadRate,
                diskWriteRate: application.diskWriteRate
            ))
        }
        for process in snapshot.backgroundProcesses {
            append(process.id, LiveProcessPoint(
                timestamp: snapshot.timestamp,
                networkThroughput: process.networkThroughput,
                cpuUsage: process.cpuUsage,
                memoryBytes: Double(process.memoryBytes),
                diskReadRate: process.diskReadRate,
                diskWriteRate: process.diskWriteRate
            ))
        }
        for id in recentProcessPoints.keys.filter({ !seen.contains($0) }) {
            recentProcessPoints.removeValue(forKey: id)
        }
    }

    /// GPU percent per pid, summed per application and per background process of the latest snapshot. Rows whose
    /// processes hold no GPU connection get no point, so the GPU list shows only GPU users.
    private func recordGPUPoints(_ byPID: [Int32: Double], at timestamp: Date) {
        guard let snapshot = processes else { return }
        let capacity = recentMetrics.capacity
        var seen = Set<String>()
        func append(_ id: String, _ value: Double) {
            seen.insert(id)
            recentGPUPoints[id, default: []].append(HistoricalPoint(timestamp: timestamp, average: value, peak: value))
            let excess = recentGPUPoints[id, default: []].count - capacity
            if excess > 0 { recentGPUPoints[id, default: []].removeFirst(excess) }
        }
        for application in snapshot.applications {
            let values = application.processes.compactMap { byPID[$0.identity.pid] }
            if !values.isEmpty || recentGPUPoints[application.id] != nil { append(application.id, values.reduce(0, +)) }
        }
        for process in snapshot.backgroundProcesses {
            let value = byPID[process.identity.pid]
            if value != nil || recentGPUPoints[process.id] != nil { append(process.id, value ?? 0) }
        }
        for id in recentGPUPoints.keys where !seen.contains(id) { recentGPUPoints.removeValue(forKey: id) }
    }

    /// Latest GPU percent per row, nil for rows without a GPU connection.
    func currentGPUUsage(_ id: String) -> Double? { recentGPUPoints[id]?.last?.average }

    func receive(_ snapshot: NetworkPortSnapshot) {
        networkPorts = snapshot
        networkPortsLoading = false
        refreshDevServers()
    }

    private var devServersWanted: Bool {
        Capabilities.supportsNetworkPortInspection &&
            ((panelVisible && (route == .devServers || (route == .summary && settingsStore.settings.shows(.devServers)))) ||
                settingsStore.settings.backgroundDevServersEnabled)
    }

    private func updateDevServerVisibility() {
        dockerModel.setVisible((panelVisible && settingsStore.settings.shows(.docker)) || devServersWanted)
        if devServersWanted { refreshDevServers() }
        else { devServerTask?.cancel() }
    }

    func refreshDevServers() {
        guard devServersWanted,
              let ports = networkPorts, let processes else { return }
        devServerTask?.cancel()
        let containers = dockerModel.snapshot?.containers ?? []
        let showSystem = settingsStore.settings.devServersShowSystem
        devServerTask = Task {
            let rows = await devServerCollector.collect(ports: ports, processes: processes,
                containers: containers, showSystem: showSystem)
            guard !Task.isCancelled else { return }
            devServers = rows.map { row in
                var row = row
                row.agentSession = agentsModel.sessions.first { session in session.listeners.contains { port in row.ports.contains { $0.pid == port.pid } } }?.id
                return row
            }
        }
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

    /// The application a process belongs to; nil for background processes.
    func application(containingProcess id: String) -> ApplicationMetrics? {
        ApplicationReadings.application(containing: id, in: processes)
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
