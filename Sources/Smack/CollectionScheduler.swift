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

actor CollectionScheduler {
    private let systemCollector: SystemMetricsCollecting
    private let processCollector: ProcessMetricsCollecting
    private let inventoryCollector: InventoryCollecting
    private let networkPortCollector: NetworkPortCollecting
    private let history: HistoryPersistence
    private let metadata: HistoryRepository
    private let onPosture: @Sendable (PostureSnapshot) -> Void
    private let onStartup: @Sendable (StartupInventory) -> Void
    private var postureTask: Task<Void, Never>?
    private var postureInterval: TimeInterval?
    private var cachedListeners: NetworkPortSnapshot?
    private let persistenceScanner = PersistenceScanner()
    private let helper: PrivilegedSamplingClient?
    private var cachedProfile: PostureCheck?
    private var lastPosture: PostureSnapshot?
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
        history: HistoryRepository,
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
        helper: PrivilegedSamplingClient? = nil,
        onAlert: @escaping @Sendable (FiredAlert) async -> ActivityEvent = { alert in
            .make(kind: .alertFired, timestamp: alert.timestamp, subject: alert.rule.name, severity: .warning, details: alert.details)
        },
        onWake: @escaping @Sendable (Date) async -> Void = { _ in },
        isPowerConstrained: @escaping @Sendable () -> Bool = PowerConstraint.current
    ) {
        self.onAlert = onAlert
        self.metadata = history
        self.helper = helper
        self.onPosture = onPosture
        self.onStartup = onStartup
        self.onWake = onWake
        self.systemCollector = systemCollector
        self.processCollector = processCollector
        self.inventoryCollector = inventoryCollector
        self.networkPortCollector = networkPortCollector
        self.history = HistoryPersistence(writer: history, onHealth: onHistoryHealth)
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
        let alertsChanged = self.settings.alertsEnabled != settings.alertsEnabled
        self.settings = settings
        updateAgentTracking()
        if alertsChanged { await alertEngine.update(rules: settings.alertsEnabled ? configuredAlertRules : []) }
        await processCollector.setNetworkSampling(visible: visible, interval: networkRateInterval)
        await restartSampling()
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

    private var networkRateInterval: TimeInterval? {
        settings.processNetworkRateEnabled ? settings.processNetworkRateSeconds : nil
    }

    /// The panel-visible period, or the background interval stretched on battery or in Low Power Mode.
    func sleepInterval(background: TimeInterval?, live: TimeInterval? = nil) -> TimeInterval? {
        if visible { return live ?? settings.liveRefreshSeconds }
        guard let background else { return nil }
        let multiplier = settings.constrainedPowerMultiplier
        return multiplier > 1 && isPowerConstrained() ? background * Double(multiplier) : background
    }

    func update(rules: [AlertRule]) async {
        configuredAlertRules = rules
        updateAgentTracking()
        await alertEngine.update(rules: settings.alertsEnabled ? rules : [])
    }

    static func wantsAgentSessions(_ settings: CollectionSettings, rules: [AlertRule]) -> Bool {
        settings.shows(.agents) || settings.records(.agents)
            || (settings.alertsEnabled && rules.contains { $0.enabled && $0.usesAgentSessions })
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
        let alertsChanged = settings.alertsEnabled != value.alertsEnabled
        settings.scheduledDriftCheck = value.scheduledDriftCheck
        settings.goldenBaselineID = value.goldenBaselineID
        settings.hiddenPages = value.hiddenPages
        settings.backgroundNetworkEnabled = value.backgroundNetworkEnabled
        settings.recordAgentEvents = value.recordAgentEvents
        settings.alertsEnabled = value.alertsEnabled
        settings.postureCheckInterval = value.postureCheckInterval
        settings.watchPersistence = value.watchPersistence
        settings.persistenceEnrichmentEnabled = value.persistenceEnrichmentEnabled
        settings.persistencePollInterval = value.persistencePollInterval
        updateAgentTracking()
        configurePosture()
        if alertsChanged { await alertEngine.update(rules: value.alertsEnabled ? configuredAlertRules : []) }
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
        if let interval = settings.backgroundInventoryInterval {
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
            if settings.alertsEnabled, let interval = sleepInterval(background: settings.backgroundSystemInterval) {
                await deliverAlerts(await alertEngine.evaluate(system: sample, expectedInterval: interval))
            }
            await history.save(system: sample)
            await deliver(await activity.record(system: sample, settings: settings))
            guard let interval = sleepInterval(background: settings.backgroundSystemInterval) else { return }
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func runProcessLoop() async {
        while !Task.isCancelled {
            let started = ProcessInfo.processInfo.systemUptime
            let snapshot = await processCollector.collectProcessSnapshot(includePrivileged: settings.privilegedSampling)
            guard !Task.isCancelled else { return }
            if var snapshot {
                if tracksAgentSessions {
                    let tracked = await agentSessions.update(snapshot, network: cachedListeners)
                    guard !Task.isCancelled else { return }
                    snapshot.agentSessions = tracked.sessions
                    await deliver(tracked.events)
                }
                onProcesses(snapshot)
                if settings.alertsEnabled, let interval = sleepInterval(background: settings.backgroundProcessInterval) {
                    await deliverAlerts(await alertEngine.evaluate(processes: snapshot, expectedInterval: interval, networkAvailable: visible && settings.processNetworkRateEnabled))
                }
                if settings.recordProcessHistory {
                    await history.save(processes: snapshot.trimmedForHistory(limit: settings.processHistoryTopCount))
                }
                await deliver(await activity.record(processes: snapshot))
            }
            guard let interval = sleepInterval(background: settings.backgroundProcessInterval) else { return }
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
            cachedListeners = snapshot
            await agentSessions.annotate(snapshot)
            await deliver(await agentSessions.annotateEvents(activity.record(network: snapshot, settings: settings)))
            guard let interval = sleepInterval(background: settings.backgroundNetworkInterval ?? (settings.backgroundDevServersEnabled ? settings.backgroundNetworkSeconds : nil), live: 5) else { return }
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
        if settings.alertsEnabled { await deliverAlerts(await alertEngine.evaluate(events: events)) }
        await persistEvents(events)
    }

    private func deliverAlerts(_ alerts: [FiredAlert]) async {
        guard settings.alertsEnabled else { return }
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
        guard settings.privilegedSampling, let helper, await helper.protocolVersion() >= 2 else { return nil }
        return await helper.dumpBackgroundTasks()
    }

    func baselineProfiles() async -> String? {
        guard settings.privilegedSampling, let helper, await helper.protocolVersion() >= 2 else { return nil }
        return await helper.listConfigurationProfiles()
    }

    private var driftRunning = false
    func checkScheduledDrift(repository: BaselineRepository = BaselineRepository(), now: Date = Date(),
                             capture: @Sendable ([MachineBaselineCollector]) async throws -> BaselineDocument = {
                                 try await BaselineCapture.capture(collectors: $0, name: "Scheduled check")
                             }) async {
        guard !Task.isCancelled, settings.scheduledDriftCheck, let golden = settings.goldenBaselineID, !driftRunning else { return }
        driftRunning = true
        defer { driftRunning = false }
        let key = "baseline.lastDriftCheck." + golden
        let last = (try? await metadata.metadata(key)).flatMap(Double.init) ?? 0
        guard now.timeIntervalSince1970 - last >= 86400 else { return }
        do {
            let base = try await repository.load(golden)
            let enabled = base.sections.keys.filter { id in
                switch id {
                case "posture": return settings.postureCheckInterval != nil
                case "startup", "profiles": return settings.watchPersistence
                case "listeners": return settings.backgroundNetworkEnabled
                case "apps": return settings.shows(.installedApps)
                case "homebrew": return settings.shows(.homebrew)
                case "runtimes": return settings.shows(.devEnvironments)
                case "agents": return settings.shows(.agents)
                case "docker": return settings.shows(.docker)
                default: return true
                }
            }
            async let profile = enabled.contains("profiles") ? baselineProfiles() : nil
            async let btm = enabled.contains("startup") ? baselineBackgroundTasks() : nil
            let (profileValue, btmValue) = await (profile, btm)
            var current = try await capture(enabled.map {
                MachineBaselineCollector(id: $0, settings: settings, listeners: cachedListeners, profiles: profileValue, backgroundTasks: btmValue)
            })
            try Task.checkCancellation()
            guard settings.scheduledDriftCheck, settings.goldenBaselineID == golden else { return }
            let skipped = Set(base.sections.keys).subtracting(enabled).sorted()
            for id in skipped { current.sections[id] = .init(status: .unavailable, error: "Collector disabled in Settings") }
            let diff = BaselineDiff.compare(base, current)
            try await metadata.setMetadata(key, value: String(now.timeIntervalSince1970))
            if diff.drift {
                var details = diff.sections.mapValues { "added=\($0.added.count),removed=\($0.removed.count),changed=\($0.changed.count)" }
                details["skipped"] = skipped.joined(separator: ",")
                await deliver([.make(kind: .driftDetected, timestamp: Date(), subject: base.name, severity: .warning, details: details)])
            }
        } catch { /* Retry on the next maintenance pass. */ }
    }

    private func maintainHistory() async {
        await checkScheduledDrift()
        await history.maintain(settings: settings)
    }

    func scanPersistence(hourly: Bool) async {
        guard settings.watchPersistence, Capabilities.supportsPersistenceWatching, !Task.isCancelled else { return }
        let (inventory, events) = await persistenceScanner.scan(metadata: metadata, enrich: settings.persistenceEnrichmentEnabled)
        guard !Task.isCancelled, settings.watchPersistence else { return }
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
        guard hourly, settings.persistencePollInterval != nil else { return }
        let cron = await CommandRunner.run("/usr/bin/crontab", ["-l"], timeout: 5, outputLimit: 65_536)
        if cron.status == 0 && !cron.truncated && !cron.cancelled {
            var sources = StartupSources(); sources.crontab = cron.output
            await record(startup: .init(timestamp: Date(), items: StartupItemCollector.items(from: sources),
                warnings: [], includesBackgroundTasks: false, includedCategories: [.scheduled]))
        }
        guard !Task.isCancelled, settings.privilegedSampling, let helper, await helper.protocolVersion() >= 2 else { return }
        if let text = await helper.dumpBackgroundTasks(), !Task.isCancelled, text.contains("Records for UID") {
            var sources = StartupSources(); sources.btm = StartupParsers.btmRecords(text)
            await record(startup: .init(timestamp: Date(), items: StartupItemCollector.items(from: sources).filter {
                StartupInventory.backgroundTaskCategories.contains($0.category)
            }, warnings: [], includesBackgroundTasks: true, includedCategories: StartupInventory.backgroundTaskCategories))
        }
        guard !Task.isCancelled, let text = await helper.listConfigurationProfiles(), !Task.isCancelled,
              let events = await persistenceScanner.profiles(text, metadata: metadata) else { return }
        await deliver(events)
        let check = PostureCheck(id: "config-profiles", status: .pass, summary: "Configuration profile inventory available (informational)",
            evidence: "Helper v2, checked \(Date().ISO8601Format()); changes tracked by digest")
        cachedProfile = check
        if var snapshot = lastPosture, let index = snapshot.checks.firstIndex(where: { $0.id == check.id }) {
            snapshot.checks[index] = check
            await savePosture(snapshot, previous: nil)
        }
    }

    func stop() {
        systemTask?.cancel(); processTask?.cancel(); inventoryTask?.cancel()
        networkPortTask?.cancel(); maintenanceTask?.cancel(); postureTask?.cancel()
    }

    private func configurePosture() {
        let interval = Capabilities.supportsPostureChecks ? settings.postureCheckInterval : nil
        guard interval != postureInterval else { return }
        postureInterval = interval
        postureTask?.cancel()
        postureTask = nil
        guard let interval else { return }
        postureTask = Task { [weak self] in
            guard let self else { return }
            var previous = await self.loadPosture()
            if let previous { await self.publishPosture(previous) }
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            while !Task.isCancelled {
                let snapshot = await PostureCollector().collect(listeners: self.cachedListeners, profile: self.cachedProfile)
                guard !Task.isCancelled else { return }
                await self.savePosture(snapshot, previous: previous)
                previous = snapshot
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        }
    }

    private func loadPosture() async -> PostureSnapshot? {
        guard let text = try? await metadata.metadata(PostureSnapshot.metadataKey) else { return nil }
        return try? JSONDecoder().decode(PostureSnapshot.self, from: Data(text.utf8))
    }

    private func publishPosture(_ snapshot: PostureSnapshot) { lastPosture = snapshot; onPosture(snapshot) }

    private func savePosture(_ snapshot: PostureSnapshot, previous: PostureSnapshot?) async {
        if let data = try? JSONEncoder().encode(snapshot), let text = String(data: data, encoding: .utf8) {
            await history.saveMetadata(PostureSnapshot.metadataKey, value: text, to: metadata)
        }
        publishPosture(snapshot)
        await deliver(snapshot.changes(from: previous))
    }

    func restoreSecurityCache() async {
        if let snapshot = await loadPosture() {
            publishPosture(snapshot)
            cachedProfile = snapshot.checks.first { $0.id == "config-profiles" }
        } else if !Capabilities.supportsPostureChecks {
            onPosture(.init(timestamp: Date(), checks: PostureParser.ids.map { .unknown($0, "Not available in this edition") }))
        }
    }
}
