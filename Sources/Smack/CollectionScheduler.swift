import Foundation
import IOKit.ps

/// Battery power or Low Power Mode, when background collection may be slowed down.
enum PowerConstraint {
    static func current() -> Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}

/// Averages process snapshots taken faster than history needs into one per interval, so a stored row stands for
/// the same span whether the panel is open or not, and a spike between two writes still reaches history. A process
/// that exits inside a window is not stored for that window.
struct ProcessHistoryAccumulator {
    private struct Totals {
        var count = 0
        var cpu = 0.0, memory = 0.0, diskRead = 0.0, diskWrite = 0.0, wakeups = 0.0

        mutating func add(_ process: ProcessMetrics) {
            count += 1
            cpu += process.cpuUsage
            memory += Double(process.memoryBytes)
            diskRead += process.diskReadRate
            diskWrite += process.diskWriteRate
            wakeups += process.wakeupsPerSecond
        }
    }

    private var lastStored: Date?
    private var totals: [String: Totals] = [:]

    /// The snapshot to store, averaged over the window it closes, or nil while the window is open. An interval of
    /// zero stores every snapshot as it is.
    mutating func add(_ snapshot: ProcessSnapshot, interval: TimeInterval) -> ProcessSnapshot? {
        for process in snapshot.applications.flatMap(\.processes) + snapshot.backgroundProcesses {
            totals[process.id, default: Totals()].add(process)
        }
        if let lastStored {
            let elapsed = snapshot.timestamp.timeIntervalSince(lastStored)
            // A backwards clock step stores rather than stalling history until the clock catches up.
            guard elapsed >= interval || elapsed < 0 else { return nil }
        }
        lastStored = snapshot.timestamp
        defer { totals.removeAll(keepingCapacity: true) }
        var averaged = snapshot
        averaged.applications = snapshot.applications.map { application in
            var application = application
            application.processes = application.processes.map(average)
            return application
        }
        averaged.backgroundProcesses = snapshot.backgroundProcesses.map(average)
        return averaged
    }

    private func average(_ process: ProcessMetrics) -> ProcessMetrics {
        guard let total = totals[process.id], total.count > 1 else { return process }
        let count = Double(total.count)
        var process = process
        process.cpuUsage = total.cpu / count
        process.memoryBytes = UInt64(total.memory / count)
        process.diskReadRate = total.diskRead / count
        process.diskWriteRate = total.diskWrite / count
        // History stores only the sum of both wakeup kinds.
        process.interruptWakeupsPerSecond = total.wakeups / count
        process.packageIdleWakeupsPerSecond = 0
        return process
    }
}

actor CollectionScheduler {
    private let systemCollector: SystemMetricsCollecting
    private let processCollector: ProcessMetricsCollecting
    private let inventoryCollector: InventoryCollecting
    private let networkPortCollector: NetworkPortCollecting
    private let history: HistoryPersistence
    private let security: SecurityMonitor
    private let onPosture: @Sendable (PostureSnapshot) -> Void
    private let onStartup: @Sendable (StartupInventory) -> Void
    private var postureTask: Task<Void, Never>?
    private var postureInterval: TimeInterval?
    private var cachedListeners: NetworkPortSnapshot?
    private let activity: any ActivityRecording
    private let alertEngine = AlertEngine()
    private var agentSessions = AgentSessionTracker()
    /// Agent sessions cost argument reads and tree walks on every process sample, so they are tracked only while
    /// something consumes them: the AI agents page, agent session events, or an enabled alert rule.
    private var tracksAgentSessions: Bool
    private var configuredAlertRules: [AlertRule] = []
    private let onAlert: @Sendable (FiredAlert) async -> ActivityEvent
    private let onWake: @Sendable (Date) async -> Void
    private var settings: CollectionSettings
    private var visible = false
    private var processHistory = ProcessHistoryAccumulator()
    /// Process history resolution while the panel is open when background process sampling is off.
    static let fallbackProcessHistoryInterval: TimeInterval = 10
    /// Pages currently showing sensor readings; counted so overlapping appear/disappear calls never cancel out.
    private var sensorClients = 0
    /// GPU pages on screen; per-process GPU time is read only while one is.
    private var gpuProcessClients = 0
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
    private let isPowerConstrained: @Sendable () -> Bool

    init(
        systemCollector: SystemMetricsCollecting,
        processCollector: ProcessMetricsCollecting,
        inventoryCollector: InventoryCollecting,
        networkPortCollector: NetworkPortCollecting,
        history: any CollectionHistoryStoring,
        settings: CollectionSettings,
        onSystem: @escaping @Sendable (SystemSample) -> Void,
        onProcesses: @escaping @Sendable (ProcessSnapshot) -> Void,
        onInventory: @escaping @Sendable (String, ProcessInventory) -> Void = { _, _ in },
        onNetworkPorts: @escaping @Sendable (NetworkPortSnapshot) -> Void = { _ in },
        onHistoryHealth: @escaping @Sendable (HistoryHealth) -> Void = { _ in },
        activity: (any ActivityRecording)? = nil,
        onEvents: @escaping @Sendable ([ActivityEvent]) -> Void = { _ in },
        onPosture: @escaping @Sendable (PostureSnapshot) -> Void = { _ in },
        onStartup: @escaping @Sendable (StartupInventory) -> Void = { _ in },
        helper: (any PrivilegedSecurityQuerying)? = nil,
        onAlert: @escaping @Sendable (FiredAlert) async -> ActivityEvent = { alert in
            .make(kind: .alertFired, timestamp: alert.timestamp, subject: alert.rule.name, severity: .warning, details: alert.details)
        },
        onWake: @escaping @Sendable (Date) async -> Void = { _ in },
        isPowerConstrained: @escaping @Sendable () -> Bool = PowerConstraint.current
    ) {
        self.onAlert = onAlert
        self.onPosture = onPosture
        self.onStartup = onStartup
        self.onWake = onWake
        self.systemCollector = systemCollector
        self.processCollector = processCollector
        self.inventoryCollector = inventoryCollector
        self.networkPortCollector = networkPortCollector
        let persistence = HistoryPersistence(writer: history, onHealth: onHistoryHealth)
        self.history = persistence
        self.security = SecurityMonitor(metadata: history, history: persistence, helper: helper)
        self.activity = activity ?? ActivityRecorder(metadata: history)
        self.settings = settings
        self.tracksAgentSessions = Self.wantsAgentSessions(settings, rules: [])
        self.onSystem = onSystem
        self.onProcesses = onProcesses
        self.onInventory = onInventory
        self.onNetworkPorts = onNetworkPorts
        self.onEvents = onEvents
        self.isPowerConstrained = isPowerConstrained
    }

    func setTemperaturesWanted(_ value: Bool) {
        sensorClients = max(0, sensorClients + (value ? 1 : -1))
    }

    func setGPUProcessesWanted(_ value: Bool) {
        gpuProcessClients = max(0, gpuProcessClients + (value ? 1 : -1))
    }

    func setVisible(_ value: Bool) async {
        visible = value
        await processCollector.setNetworkSampling(visible: value, interval: networkRateInterval)
        guard visible == value else { return }
        await restartSampling()
    }

    func update(settings: CollectionSettings) async {
        let alertsChanged = self.settings.automation.alertsEnabled != settings.automation.alertsEnabled
        self.settings = settings
        updateAgentTracking()
        if alertsChanged { await alertEngine.update(rules: settings.automation.alertsEnabled ? configuredAlertRules : []) }
        await processCollector.setNetworkSampling(visible: visible, interval: networkRateInterval)
        await restartSampling()
        await maintainHistory()
    }

    func inventory(for process: ProcessMetrics) async -> ProcessInventory {
        await inventoryCollector.collectInventory(
            for: process,
            includePrivileged: settings.sampling.privilegedSampling
        )
    }

    func networkPorts() async -> NetworkPortSnapshot {
        await networkPortCollector.collectNetworkPorts(
            includePrivileged: settings.sampling.privilegedSampling
        )
    }

    private var processHistoryInterval: TimeInterval {
        settings.sampling.backgroundProcessInterval ?? Self.fallbackProcessHistoryInterval
    }

    private var networkRateInterval: TimeInterval? {
        settings.sampling.processNetworkRateEnabled ? settings.sampling.processNetworkRateSeconds : nil
    }

    /// The panel-visible period, or the background interval stretched on battery or in Low Power Mode.
    func sleepInterval(background: TimeInterval?, live: TimeInterval? = nil) -> TimeInterval? {
        if visible { return live ?? settings.sampling.liveRefreshSeconds }
        guard let background else { return nil }
        let multiplier = settings.sampling.constrainedPowerMultiplier
        return multiplier > 1 && isPowerConstrained() ? background * Double(multiplier) : background
    }

    func update(rules: [AlertRule]) async {
        configuredAlertRules = rules
        updateAgentTracking()
        await alertEngine.update(rules: settings.automation.alertsEnabled ? rules : [])
    }

    static func wantsAgentSessions(_ settings: CollectionSettings, rules: [AlertRule]) -> Bool {
        settings.shows(.agents) || settings.shows(.projects) || settings.records(.agents)
            || (settings.automation.alertsEnabled && rules.contains { $0.enabled && $0.usesAgentSessions })
    }

    /// A stopped tracker is dropped, so restarting seeds from the running processes instead of reporting
    /// sessions that started or ended while it was off.
    private func updateAgentTracking() {
        let wanted = Self.wantsAgentSessions(settings, rules: configuredAlertRules)
        if tracksAgentSessions, !wanted { agentSessions = AgentSessionTracker() }
        tracksAgentSessions = wanted
    }

    var isTrackingAgentSessions: Bool { tracksAgentSessions }

    func updateFeatureSettings(_ value: CollectionSettings) async {
        let alertsChanged = settings.automation.alertsEnabled != value.automation.alertsEnabled
        settings.security.scheduledDriftCheck = value.security.scheduledDriftCheck
        settings.security.goldenBaselineID = value.security.goldenBaselineID
        settings.hiddenPages = value.hiddenPages
        settings.sampling.backgroundNetworkEnabled = value.sampling.backgroundNetworkEnabled
        settings.activity.recordAgentEvents = value.activity.recordAgentEvents
        settings.automation.alertsEnabled = value.automation.alertsEnabled
        settings.security.postureCheckInterval = value.security.postureCheckInterval
        settings.security.watchPersistence = value.security.watchPersistence
        settings.security.persistenceEnrichmentEnabled = value.security.persistenceEnrichmentEnabled
        settings.security.persistencePollInterval = value.security.persistencePollInterval
        updateAgentTracking()
        configurePosture()
        if alertsChanged { await alertEngine.update(rules: value.automation.alertsEnabled ? configuredAlertRules : []) }
    }

    func alertRuntime() async -> [UUID: AlertRuntime] { await alertEngine.runtime }

    private func restartSampling() async {
        configurePosture()
        await alertEngine.noteGap(at: Date())
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
        if let interval = settings.sampling.backgroundInventoryInterval {
            inventoryTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.runScheduledInventory()
                    try? await Task.sleep(for: .seconds(await self.sleepInterval(background: interval, live: interval) ?? interval))
                }
            }
        }
    }

    private func runSystemLoop() async {
        while !Task.isCancelled {
            let sample = systemCollector.collectSystemSample(
                includeTemperatures: visible && sensorClients > 0,
                includeGPUProcesses: visible && gpuProcessClients > 0
            )
            onSystem(sample)
            if settings.automation.alertsEnabled, let interval = sleepInterval(background: settings.sampling.backgroundSystemInterval) {
                await deliverAlerts(await alertEngine.evaluate(system: sample, expectedInterval: interval))
            }
            await history.save(system: sample)
            await deliver(await activity.record(system: sample, settings: settings))
            guard let interval = sleepInterval(background: settings.sampling.backgroundSystemInterval) else { return }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func runProcessLoop() async {
        while !Task.isCancelled {
            let started = ProcessInfo.processInfo.systemUptime
            let snapshot = await processCollector.collectProcessSnapshot(includePrivileged: settings.sampling.privilegedSampling)
            guard !Task.isCancelled else { return }
            if var snapshot {
                if tracksAgentSessions {
                    let tracked = await agentSessions.update(snapshot, network: cachedListeners)
                    guard !Task.isCancelled else { return }
                    snapshot.agentSessions = tracked.sessions
                    await deliver(tracked.events)
                }
                onProcesses(snapshot)
                if settings.automation.alertsEnabled, let interval = sleepInterval(background: settings.sampling.backgroundProcessInterval) {
                    await deliverAlerts(await alertEngine.evaluate(processes: snapshot, expectedInterval: interval, networkAvailable: visible && settings.sampling.processNetworkRateEnabled))
                }
                // While the panel is open, history keeps the background resolution instead of the live refresh rate;
                // in the background each snapshot already is one interval.
                if settings.history.recordProcessHistory,
                   let stored = processHistory.add(snapshot, interval: visible ? processHistoryInterval : 0) {
                    await history.save(processes: stored.trimmedForHistory(limit: settings.history.processHistoryTopCount))
                }
                await deliver(await activity.record(processes: snapshot))
            }
            guard let interval = sleepInterval(background: settings.sampling.backgroundProcessInterval) else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            try? await Task.sleep(for: .seconds(max(0.05, interval - elapsed)))
        }
    }

    private func runNetworkPortLoop() async {
        guard Capabilities.supportsNetworkPortInspection else { return }
        while !Task.isCancelled {
            let snapshot = await networkPortCollector.collectNetworkPorts(
                includePrivileged: settings.sampling.privilegedSampling
            )
            guard !Task.isCancelled else { return }
            onNetworkPorts(snapshot)
            cachedListeners = snapshot
            await agentSessions.annotate(snapshot)
            await deliver(await agentSessions.annotateEvents(activity.record(network: snapshot, settings: settings)))
            guard let interval = sleepInterval(background: settings.sampling.backgroundNetworkInterval ?? (settings.devTools.backgroundDevServersEnabled ? settings.sampling.backgroundNetworkSeconds : nil), live: 5) else { return }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func runScheduledInventory() async {
        guard !visible, !Capabilities.isSandboxed else { return }
        guard let snapshot = await processCollector.collectProcessSnapshot(includePrivileged: settings.sampling.privilegedSampling),
              !Task.isCancelled else { return }
        let processes = snapshot.applications.flatMap(\.processes) + snapshot.backgroundProcesses
        for process in processes {
            guard !Task.isCancelled else { return }
            let inventory = await inventoryCollector.collectInventory(
                for: process,
                includePrivileged: settings.sampling.privilegedSampling
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
        if settings.automation.alertsEnabled { await deliverAlerts(await alertEngine.evaluate(events: events)) }
        await persistEvents(events)
    }

    private func deliverAlerts(_ alerts: [FiredAlert]) async {
        guard settings.automation.alertsEnabled else { return }
        for alert in alerts { await persistEvents([await onAlert(alert)]) }
    }

    private func persistEvents(_ events: [ActivityEvent]) async {
        let settings = settings
        let events = events.filter { settings.records($0.kind.group) }
        guard !events.isEmpty else { return }
        await history.save(events: events)
        onEvents(events)
    }

    func record(startup inventory: StartupInventory) async {
        onStartup(inventory)
        await deliver(await activity.record(startup: inventory))
    }

    func recordVolumeMounted(path: String, name: String) async {
        await deliver([await activity.recordVolumeMounted(path: path, name: name)])
    }

    func recordVolumeUnmounted(path: String) async {
        await deliver([await activity.recordVolumeUnmounted(path: path)])
    }

    func recordSleep() async {
        await alertEngine.noteGap(at: Date())
        await deliver([await activity.recordSleep(at: Date())])
        await history.flush()
    }

    func recordWake() async {
        await alertEngine.noteGap(at: Date())
        await onWake(Date())
        await deliver([await activity.recordWake(at: Date())])
    }

    func recordPowerSource(charging: Bool, chargePercent: Double?) async {
        await deliver([await activity.recordPowerSource(charging: charging, chargePercent: chargePercent)])
    }

    func baselineBackgroundTasks() async -> String? {
        await security.backgroundTasks(privileged: settings.sampling.privilegedSampling)
    }

    func baselineProfiles() async -> String? {
        await security.configurationProfiles(privileged: settings.sampling.privilegedSampling)
    }

    func checkScheduledDrift(repository: BaselineRepository = BaselineRepository(), now: Date = Date(),
                             capture: @Sendable ([MachineBaselineCollector]) async throws -> BaselineDocument = {
                                 try await BaselineCapture.capture(collectors: $0, name: "Scheduled check")
                             }) async {
        let event = await security.checkScheduledDrift(
            settings: { await self.settings }, networkPorts: { await self.networkPorts() },
            repository: repository, now: now, capture: capture
        )
        if let event { await deliver([event]) }
    }

    private func maintainHistory() async {
        await checkScheduledDrift()
        await history.maintain(settings: settings)
    }

    /// Steps run in order and re-check settings after each suspension; every event goes through `deliver`.
    func scanPersistence(hourly: Bool) async {
        guard settings.security.watchPersistence, Capabilities.supportsPersistenceWatching, !Task.isCancelled else { return }
        let (inventory, events) = await security.scanPersistence(enrich: settings.security.persistenceEnrichmentEnabled)
        guard !Task.isCancelled, settings.security.watchPersistence else { return }
        if let inventory {
            onStartup(inventory)
            var startupEvents = await activity.record(startup: inventory)
            for index in startupEvents.indices {
                if let id = startupEvents[index].details["item"],
                   let enriched = events.first(where: { "launchd:" + $0.subject == id }) {
                    startupEvents[index].details.merge(enriched.details) { _, new in new }
                }
            }
            await deliver(startupEvents)
        }
        await deliver(events)
        guard hourly, settings.security.persistencePollInterval != nil else { return }
        if let cron = await SecurityMonitor.crontabInventory() { await record(startup: cron) }
        guard !Task.isCancelled else { return }
        let privileged = settings.sampling.privilegedSampling
        if let text = await security.backgroundTasks(privileged: privileged), !Task.isCancelled,
           let inventory = SecurityMonitor.backgroundTaskInventory(text) {
            await record(startup: inventory)
        }
        guard !Task.isCancelled, let text = await security.configurationProfiles(privileged: privileged), !Task.isCancelled,
              let events = await security.profileEvents(text) else { return }
        await deliver(events)
        let check = PostureCheck(id: "config-profiles", status: .pass, summary: "Configuration profile inventory available (informational)",
            evidence: "Helper v2, checked \(Date().ISO8601Format()); changes tracked by digest")
        if let snapshot = await security.recordProfileCheck(check) { await savePosture(snapshot, previous: nil) }
    }

    func stop() {
        systemTask?.cancel(); processTask?.cancel(); inventoryTask?.cancel()
        networkPortTask?.cancel(); maintenanceTask?.cancel(); postureTask?.cancel()
    }

    private func configurePosture() {
        let interval = Capabilities.supportsPostureChecks ? settings.security.postureCheckInterval : nil
        guard interval != postureInterval else { return }
        postureInterval = interval
        postureTask?.cancel()
        postureTask = nil
        guard let interval else { return }
        postureTask = Task { [weak self] in
            guard let self else { return }
            var previous = await self.security.loadPosture()
            if let previous { await self.publishPosture(previous) }
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            while !Task.isCancelled {
                let snapshot = await self.security.collectPosture(listeners: self.cachedListeners)
                guard !Task.isCancelled else { return }
                await self.savePosture(snapshot, previous: previous)
                previous = snapshot
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        }
    }

    private func publishPosture(_ snapshot: PostureSnapshot) async {
        await security.remember(snapshot)
        onPosture(snapshot)
    }

    private func savePosture(_ snapshot: PostureSnapshot, previous: PostureSnapshot?) async {
        await security.save(snapshot)
        onPosture(snapshot)
        await deliver(snapshot.changes(from: previous))
    }

    func restoreSecurityCache() async {
        if let snapshot = await security.restoreCache() {
            onPosture(snapshot)
        } else if !Capabilities.supportsPostureChecks {
            onPosture(.init(timestamp: Date(), checks: PostureParser.ids.map { .unknown($0, "Not available in this edition") }))
        }
    }
}
