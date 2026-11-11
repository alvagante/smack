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
    case projects
    case documents
    case document(String)
    case project(String)
    case userHome
    case agents
    case agentSession(String)
    case installedApps
    case startupItems
    case timeline
    case history
    case insights
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
    /// Hostname and primary network for the titlebar, re-read only when interface addresses change.
    @Published private(set) var hostIdentity = HostIdentity()
    private var hostIdentityKey: [String: [String]]?
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
    /// Recent samples per application and background-process ID, bounded by `LiveMetricHistory`'s capacity.
    private(set) var recentProcessPoints: [String: [LiveProcessPoint]] = [:]
    /// Live GPU percent per application and background-process ID while the GPU page is open; never stored.
    private(set) var recentGPUPoints: [String: [HistoricalPoint]] = [:]

    var recentCPU: [HistoricalPoint] {
        recentMetrics.points.map { HistoricalPoint(timestamp: $0.timestamp, average: $0.cpuUsage, peak: $0.cpuUsage) }
    }
    private var dockerObservation: AnyCancellable?
    @Published private(set) var networkPorts: NetworkPortSnapshot?
    @Published private(set) var networkPortsLoading = false
    @Published var errorMessage: String?
    @Published private(set) var historyHealth = HistoryHealth()

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
        didSet { alertDispatcher?.enabled = settingsStore.settings.automation.alertsEnabled }
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
           devServersModel.devServers?.contains(where: { $0.ports.contains(where: { $0.port == port }) }) == true {
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
    let applicationListEnrichment = ApplicationListEnrichment()
    let processDetailViewModel = ProcessDetailViewModel()
    let networkPortsViewModel = NetworkPortsViewModel()
    let settingsViewModel = SettingsViewModel()
    let storageScanModel: StorageScanModel
    let startupItemsModel = StartupItemsModel()
    let dockerModel = DockerMonitor()
    let homebrewModel = HomebrewMonitor()
    let devEnvironmentModel = DevEnvironmentMonitor()
    let projectsModel = ProjectsMonitor()
    private var pendingProjectSection: ProjectSection?
    let userHomeModel = UserHomeMonitor()
    let documentsModel = DocumentsModel()
    let agentsModel = AgentMonitor()
    let installedAppsModel = InstalledAppsMonitor()
    let baselines = BaselineModel()
    let insights: InsightsModel
    let activityFeed: ActivityFeedModel
    let inspection: ProcessInspectionModel
    let devServersModel = DevServersModel()
    func captureBaseline(name: String, sections: [String]? = nil) async throws -> BaselineDocument {
        let settings = settingsStore.settings
        let ids = sections ?? BaselineDiff.rules.keys.sorted()
        async let profiles = ids.contains("profiles") ? scheduler.baselineProfiles() : nil
        async let btm = ids.contains("startup") ? scheduler.baselineBackgroundTasks() : nil
        async let listeners: NetworkPortSnapshot? = (ids.contains("listeners") || ids.contains("posture")) && Capabilities.supportsNetworkPortInspection
            ? scheduler.networkPorts() : nil
        let (profileValue, btmValue, listenerValue) = await (profiles, btm, listeners)
        try Task.checkCancellation()
        return try await BaselineCapture.capture(collectors: ids.map {
            MachineBaselineCollector(id: $0, settings: settings, listeners: listenerValue, profiles: profileValue, backgroundTasks: btmValue)
        }, name: name, progress: { [weak self] id, section in
            await MainActor.run { self?.baselines.progress[id] = section.status.rawValue }
        })
    }
    private let scheduler: CollectionScheduler
    private var networkPortsTask: Task<Void, Never>?
    private var panelVisible = false
    /// Observable copy of `panelVisible`, so on-screen work such as the Session Timeline stops with the Panel.
    let panelVisibility = PanelVisibility(visible: false)
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
    init(
        settingsStore: SettingsStore,
        history: HistoryRepository,
        scheduler: CollectionScheduler,
        privilegedSampling: PrivilegedSamplingController? = nil,
        defaults: UserDefaults = .standard,
        knowledgeBase: ProcessKnowledgeBase = .shared
    ) {
        self.settingsStore = settingsStore
        self.privilegedSampling = privilegedSampling
        storageScanModel = StorageScanModel(helper: privilegedSampling)
        self.history = history
        self.scheduler = scheduler
        activityFeed = ActivityFeedModel(events: history, metadata: history, defaults: defaults)
        insights = InsightsModel(history: history)
        inspection = ProcessInspectionModel(knowledgeBase: knowledgeBase) { process in await scheduler.inventory(for: process) }
        historyViewModel.showEvents = settingsStore.settings.activity.showEventsOnCharts
        startupItemsModel.onInventory = { [weak self] inventory in
            guard let self else { return }
            Task { await self.recordStartup(inventory) }
        }
        devEnvironmentModel.onFoldersChanged = { [weak settingsStore] folders in
            settingsStore?.update { $0.devTools.devProjectFolders = folders }
        }
        projectsModel.onFoldersChanged = { [weak settingsStore] folders in
            settingsStore?.update { $0.devTools.devProjectFolders = folders }
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
        settingsStore.settings.sampling.processNetworkRateEnabled ? "Unavailable" : "Off"
    }

    /// Pushes settings that do not affect sampling to the page monitors, at launch and on every change.
    private func applyEnvironmentSettings(_ settings: CollectionSettings) {
        let enableAlerts = settings.automation.alertsEnabled && alertDispatcher?.enabled == false
        alertDispatcher?.enabled = settings.automation.alertsEnabled
        if enableAlerts { Task { await alertDispatcher?.prepare(rules: alertRules.rules) } }
        if securityMonitoringStarted {
            Task { await scheduler.updateFeatureSettings(settings) }
            if enrichmentEnabled != settings.security.persistenceEnrichmentEnabled { persistenceWatcher?.stop() }
            enrichmentEnabled = settings.security.persistenceEnrichmentEnabled
            if settings.security.watchPersistence { persistenceWatcher?.start(pollInterval: settings.security.persistencePollInterval) }
            else { persistenceWatcher?.stop() }
        }
        dockerModel.configure(refreshSeconds: settings.devTools.dockerRefreshSeconds, liveStats: settings.devTools.dockerLiveStats, cache: settings.devTools.inventoryCache)
        homebrewModel.cache = settings.devTools.inventoryCache
        devEnvironmentModel.configure(folders: settings.devTools.devProjectFolders, depth: settings.devTools.devScanDepth, cache: settings.devTools.inventoryCache)
        projectsModel.configure(folders: settings.devTools.devProjectFolders, depth: settings.devTools.devScanDepth, cache: settings.devTools.inventoryCache)
        agentsModel.configure(excluded: settings.devTools.excludedAgents, customFolders: settings.devTools.customAgentFolders, cache: settings.devTools.inventoryCache)
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
        if pages.contains(.projects) { projectsModel.setVisible(show(.projects)) }
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

    /// GPU views ask for per-process GPU time while on screen; balance every `true` with one `false`.
    func setGPUProcessesWanted(_ wanted: Bool) {
        Task { await scheduler.setGPUProcessesWanted(wanted) }
    }

    func setVisible(_ visible: Bool) {
        Task { await scheduler.setVisible(visible) }
        // Only a real transition counts: the launch-time hide must not overwrite the previous session's last look.
        guard visible != panelVisible else { return }
        panelVisible = visible
        panelVisibility.visible = visible
        setPageMonitorsVisible(visible)
        updateDevServerVisibility()
        activityFeed.panelVisibilityChanged(visible) { [weak self] in self?.processes }
    }

    // MARK: Activity

    func receive(_ events: [ActivityEvent]) {
        let fresh = activityFeed.receive(events)
        guard !fresh.isEmpty else { return }
        AutomationSnapshot.publish(fresh, from: self)
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

    func settingsChanged() {
        historyViewModel.showEvents = settingsStore.settings.activity.showEventsOnCharts
        Task { await scheduler.update(settings: settingsStore.settings) }
    }

    func receive(_ health: HistoryHealth) {
        guard health.revision > historyHealth.revision else { return }
        historyHealth = health
    }

    func receive(_ sample: SystemSample) {
        system = sample
        let addresses = Dictionary(sample.interfaces.map { ($0.name, $0.addresses) }, uniquingKeysWith: { first, _ in first })
        if addresses != hostIdentityKey {
            hostIdentityKey = addresses
            hostIdentity = .current()
        }
        // Samples carry GPU clients only while a GPU view requests them; once they stop, the live window is dropped.
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
        agentsModel.receive(snapshot.agentSessions, at: snapshot.timestamp)
        if devServersModel.devServers == nil { refreshDevServers() }
        let liveIDs = Set(snapshot.applications.flatMap(\.processes).map(\.id) + snapshot.backgroundProcesses.map(\.id))
        inspection.retainScheduled(liveIDs)
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
            ((panelVisible && (route == .devServers || showsProjectsRoute ||
                (route == .summary && (settingsStore.settings.shows(.devServers) || settingsStore.settings.shows(.projects))))) ||
                settingsStore.settings.devTools.backgroundDevServersEnabled)
    }

    /// Projects and their Detail Pages join dev servers, Docker Compose containers and agent sessions already in memory.
    private var showsProjectsRoute: Bool {
        switch route {
        case .projects, .project: true
        default: false
        }
    }

    private func updateDevServerVisibility() {
        dockerModel.setVisible((panelVisible && settingsStore.settings.shows(.docker)) || devServersWanted)
        if devServersWanted { refreshDevServers() }
        else { devServersModel.cancel() }
    }

    func refreshDevServers() {
        guard devServersWanted,
              let ports = networkPorts, let processes else { return }
        devServersModel.refresh(ports: ports, processes: processes, containers: dockerModel.snapshot?.containers ?? [],
            showSystem: settingsStore.settings.devTools.devServersShowSystem) { [agentsModel] in agentsModel.sessions }
    }

    func receive(_ inventory: ProcessInventory, for id: String) {
        guard process(id: id) != nil else { return }
        inspection.receiveScheduled(inventory, for: id)
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

    func project(root: String) -> ProjectRecord? { projectsModel.project(root: root) }

    /// Dev servers, Compose containers, Agent Sessions and Development Environments already in memory that belong to
    /// the repository. Development Environments appear only if their own discovery has run; this never starts it.
    func links(forProject root: String) -> ProjectLinks {
        ProjectRelation.links(forRoot: root, servers: devServersModel.devServers ?? [],
                              containers: dockerModel.snapshot?.containers ?? [], sessions: agentsModel.sessions,
                              environments: devEnvironmentModel.snapshot?.environments ?? [])
    }

    /// Opens a Project Detail Page on one section; the page takes the section once when it appears.
    func openProject(_ root: String, section: ProjectSection = .overview) {
        pendingProjectSection = section
        route = .project(root)
    }

    func takeProjectSection() -> ProjectSection? {
        defer { pendingProjectSection = nil }
        return pendingProjectSection
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

    func loadProvenance(for process: ProcessMetrics) {
        inspection.loadProvenance(for: process, in: processes, startup: startupItemsModel.inventory)
    }

    func launchdIndex() -> [String: LaunchdMatch] { inspection.launchdIndex(from: startupItemsModel.inventory) }

    func systemHistory(_ metric: SystemMetric, hours: Double = 1) async -> [HistoricalPoint] {
        await systemHistory(metric, from: Date().addingTimeInterval(-hours * 3600))
    }

    func systemHistory(_ metric: SystemMetric, from start: Date, to end: Date = .distantFuture) async -> [HistoricalPoint] {
        do {
            return try await history.systemSeries(metric, from: start, to: end)
        } catch {
            errorMessage = "History could not be read: \(error.localizedDescription)"
            return []
        }
    }

    /// Every metric for one instance (`processID`), or summed over all instances of `program`.
    func processHistory(program: String, processID: String?, hours: Double, limit: Int) async -> [ProcessMetric: [HistoricalPoint]] {
        await processHistory(program: program, processID: processID, from: Date().addingTimeInterval(-hours * 3600), limit: limit)
    }

    func processHistory(program: String, processID: String?, from start: Date, to end: Date = .distantFuture, limit: Int) async -> [ProcessMetric: [HistoricalPoint]] {
        do {
            return try await history.processHistory(program: program, processID: processID, from: start, to: end, limit: limit)
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

    func historicalPrograms(from start: Date, to end: Date) async -> [HistoricalProgram] {
        do {
            return try await history.programs(from: start, to: end)
        } catch {
            errorMessage = "History could not be read: \(error.localizedDescription)"
            return []
        }
    }

    func eventCounts(from start: Date, to end: Date) async -> [ActivityEventKind: Int] {
        (try? await history.eventCounts(from: start, to: end)) ?? [:]
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
