import Combine
import Foundation

@MainActor
final class MonitorStore: ObservableObject, EnvironmentContext {
    @Published private(set) var posture: PostureSnapshot?
    func receive(_ snapshot: PostureSnapshot) { posture = snapshot }
    func receive(_ inventory: StartupInventory) { startupItemsModel.receiveCached(inventory) }
    @Published var system: SystemSample?
    /// Hostname and primary network for the titlebar, re-read only when interface addresses change.
    @Published private(set) var hostIdentity = HostIdentity()
    private var hostIdentityKey: [String: [String]]?
    @Published var processes: ProcessSnapshot?
    @Published private var navigation = NavigationState()
    var route: AppRoute {
        get { navigation.route }
        set { updateNavigation { $0.navigate(to: newValue) } }
    }
    var previousRoute: AppRoute? { navigation.previousRoute }
    var navigationFilters: ViewFilters { navigation.filters }
    private var liveMetrics = LiveMetrics()
    var recentMetrics: LiveMetricHistory { liveMetrics.system }
    var recentCPU: [HistoricalPoint] { liveMetrics.cpuPoints }
    /// Recent samples per application and background-process ID, bounded by `LiveMetricHistory`'s capacity.
    var recentProcessPoints: [String: [LiveProcessPoint]] { liveMetrics.processPoints }
    /// Live GPU percent per application and background-process ID while the GPU page is open; never stored.
    var recentGPUPoints: [String: [HistoricalPoint]] { liveMetrics.gpuPoints }
    private func updateNavigation(_ change: (inout NavigationState) -> Void) {
        let previous = route
        change(&navigation)
        if route != previous { environment.routeChanged() }
    }
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
        return filterable(for: route)?.shows(link.filters) ?? true
    }

    /// The view model that owns a route's deep-link filters; nil for routes without any.
    private func filterable(for route: AppRoute) -> (any DeepLinkFilterable)? {
        switch route {
        case .networkPorts: networkPortsViewModel
        case .applications: applicationListViewModel
        case .timeline: timelineViewModel
        case .settings: settingsViewModel
        default: nil
        }
    }

    func resolveDeepLink(_ url: URL) -> DeepLink {
        var link = DeepLinkParser.parse(url, resolveProcess: { self.process(pid: $0)?.id },
            resolveApplication: { bundle in self.processes?.applications.first { $0.bundleIdentifier == bundle }?.id })
        if link.route == .networkPorts, let port = link.filters.port,
           environment.devServersModel.devServers?.contains(where: { $0.ports.contains(where: { $0.port == port }) }) == true {
            link.route = .devServers
        }
        return link
    }

    func navigate(to url: URL, now: Date = Date()) {
        let link = resolveDeepLink(url)
        filterable(for: link.route)?.apply(link.filters, now: now)
        updateNavigation { $0.navigate(to: link.route, filters: link.filters) }
    }

    let settingsStore: SettingsStore
    let privilegedSampling: PrivilegedSamplingController?
    let historicalData: HistoricalDataQueries
    let baselineCoordinator: BaselineCoordinator
    let securityMonitoring: SecurityMonitoring
    var baselines: BaselineModel { baselineCoordinator.model }
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
    let environment: EnvironmentMonitoring
    let userHomeModel = UserHomeMonitor()
    let documentsModel = DocumentsModel()
    let insights: InsightsModel
    let activityFeed: ActivityFeedModel
    let inspection: ProcessInspectionModel
    private let scheduler: CollectionScheduler
    private var networkPortsTask: Task<Void, Never>?
    private var panelVisible = false
    var isPanelVisible: Bool { panelVisible }
    /// Observable copy of `panelVisible`, so on-screen work such as the Session Timeline stops with the Panel.
    let panelVisibility = PanelVisibility(visible: false)
    private var settingsObservation: AnyCancellable?
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
        self.scheduler = scheduler
        historicalData = HistoricalDataQueries(history: history)
        baselineCoordinator = BaselineCoordinator(settingsStore: settingsStore, scheduler: scheduler)
        securityMonitoring = SecurityMonitoring(controller: scheduler)
        environment = EnvironmentMonitoring(settingsStore: settingsStore)
        activityFeed = ActivityFeedModel(events: history, metadata: history, defaults: defaults)
        insights = InsightsModel(history: history)
        inspection = ProcessInspectionModel(knowledgeBase: knowledgeBase) { process in await scheduler.inventory(for: process) }
        historyViewModel.showEvents = settingsStore.settings.activity.showEventsOnCharts
        startupItemsModel.onInventory = { [weak self] inventory in
            guard let self else { return }
            Task { await self.recordStartup(inventory) }
        }
        historicalData.onError = { [weak self] message in self?.errorMessage = message }
        environment.context = self
        applyEnvironmentSettings(settingsStore.settings)
        // Every writer goes through SettingsStore, including ones that skip settingsChanged(), so observe it here.
        // The window frame is saved while the user drags; it configures no feature, so it re-applies nothing.
        settingsObservation = settingsStore.$settings.map { settings in
            var features = settings
            features.panel.savedWindowFrame = nil
            return features
        }.removeDuplicates().dropFirst().sink { [weak self] settings in
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
        securityMonitoring.apply(settings: settings)
        environment.apply(settings: settings)
    }

    func goBack() {
        updateNavigation { $0.goBack() }
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
        environment.visibilityChanged()
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
        liveMetrics.receive(sample, processes: processes)
        system = sample
        let addresses = Dictionary(sample.interfaces.map { ($0.name, $0.addresses) }, uniquingKeysWith: { first, _ in first })
        if addresses != hostIdentityKey {
            hostIdentityKey = addresses
            hostIdentity = .current()
        }
    }

    func receive(_ snapshot: ProcessSnapshot) {
        guard processes.map({ snapshot.timestamp > $0.timestamp }) ?? true else { return }
        liveMetrics.receive(snapshot)
        processes = snapshot
        environment.receive(snapshot)
        let liveIDs = Set(snapshot.applications.flatMap(\.processes).map(\.id) + snapshot.backgroundProcesses.map(\.id))
        inspection.retainScheduled(liveIDs)
    }

    func currentGPUUsage(_ id: String) -> Double? { liveMetrics.currentGPUUsage(id) }

    func receive(_ snapshot: NetworkPortSnapshot) {
        networkPorts = snapshot
        networkPortsLoading = false
        environment.networkPortsChanged()
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

    /// Opens a Project Detail Page on one section; the page takes the section once when it appears.
    func openProject(_ root: String, section: ProjectSection = .overview) {
        updateNavigation { $0.openProject(root, section: section) }
    }

    func takeProjectSection() -> ProjectSection? {
        navigation.takeProjectSection()
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
}
