import Foundation

/// Security state collection: posture checks, persistence scans, helper-backed inventories and scheduled drift.
/// It runs the work and returns results; `CollectionScheduler` decides when it runs, re-checks settings between
/// steps, and delivers every event through its single path.
actor SecurityMonitor {
    private let metadata: any ActivityMetadataStoring
    private let history: HistoryPersistence
    private let helper: (any PrivilegedSecurityQuerying)?
    private let persistenceScanner = PersistenceScanner()
    private var cachedProfile: PostureCheck?
    private var lastPosture: PostureSnapshot?
    private var driftRunning = false

    /// `history` is the scheduler's instance, so security writes share its health reporting.
    init(metadata: any ActivityMetadataStoring, history: HistoryPersistence, helper: (any PrivilegedSecurityQuerying)?) {
        self.metadata = metadata
        self.history = history
        self.helper = helper
    }

    // MARK: Posture

    func loadPosture() async -> PostureSnapshot? {
        guard let text = try? await metadata.metadata(PostureSnapshot.metadataKey) else { return nil }
        return try? JSONDecoder().decode(PostureSnapshot.self, from: Data(text.utf8))
    }

    /// The stored snapshot, also restoring the cached configuration profile check.
    func restoreCache() async -> PostureSnapshot? {
        guard let snapshot = await loadPosture() else { return nil }
        lastPosture = snapshot
        cachedProfile = snapshot.checks.first { $0.id == "config-profiles" }
        return snapshot
    }

    func collectPosture(listeners: NetworkPortSnapshot?) async -> PostureSnapshot {
        await PostureCollector().collect(listeners: listeners, profile: cachedProfile)
    }

    /// The snapshot the scheduler just published.
    func remember(_ snapshot: PostureSnapshot) { lastPosture = snapshot }

    func save(_ snapshot: PostureSnapshot) async {
        if let data = try? JSONEncoder().encode(snapshot), let text = String(data: data, encoding: .utf8) {
            await history.saveMetadata(PostureSnapshot.metadataKey, value: text, to: metadata)
        }
        lastPosture = snapshot
    }

    /// Caches the profile check and returns the last snapshot patched with it, when that snapshot has one to replace.
    func recordProfileCheck(_ check: PostureCheck) -> PostureSnapshot? {
        cachedProfile = check
        guard var snapshot = lastPosture, let index = snapshot.checks.firstIndex(where: { $0.id == check.id }) else { return nil }
        snapshot.checks[index] = check
        return snapshot
    }

    // MARK: Helper queries (protocol v2)

    func backgroundTasks(privileged: Bool) async -> String? {
        guard privileged, let helper, await helper.protocolVersion() >= 2 else { return nil }
        return await helper.dumpBackgroundTasks()
    }

    func configurationProfiles(privileged: Bool) async -> String? {
        guard privileged, let helper, await helper.protocolVersion() >= 2 else { return nil }
        return await helper.listConfigurationProfiles()
    }

    // MARK: Persistence

    func scanPersistence(enrich: Bool) async -> (StartupInventory?, [ActivityEvent]) {
        await persistenceScanner.scan(metadata: metadata, enrich: enrich)
    }

    func profileEvents(_ text: String) async -> [ActivityEvent]? {
        await persistenceScanner.profiles(text, metadata: metadata)
    }

    static func crontabInventory() async -> StartupInventory? {
        let cron = await CommandRunner.run("/usr/bin/crontab", ["-l"], timeout: 5, outputLimit: 65_536)
        guard cron.status == 0 && !cron.truncated && !cron.cancelled else { return nil }
        var sources = StartupSources(); sources.crontab = cron.output
        return .init(timestamp: Date(), items: StartupItemCollector.items(from: sources),
            warnings: [], includesBackgroundTasks: false, includedCategories: [.scheduled])
    }

    static func backgroundTaskInventory(_ text: String) -> StartupInventory? {
        guard text.contains("Records for UID") else { return nil }
        var sources = StartupSources(); sources.btm = StartupParsers.btmRecords(text)
        return .init(timestamp: Date(), items: StartupItemCollector.items(from: sources).filter {
            StartupInventory.backgroundTaskCategories.contains($0.category)
        }, warnings: [], includesBackgroundTasks: true, includedCategories: StartupInventory.backgroundTaskCategories)
    }

    // MARK: Scheduled drift

    /// Compares the machine with the golden baseline at most once a day. `settings` is read again after every
    /// suspension, so a check disabled mid-capture is dropped. Returns the drift event, if any.
    func checkScheduledDrift(
        settings current: @Sendable () async -> CollectionSettings,
        networkPorts: @Sendable () async -> NetworkPortSnapshot,
        repository: BaselineRepository, now: Date,
        capture: @Sendable ([MachineBaselineCollector]) async throws -> BaselineDocument
    ) async -> ActivityEvent? {
        let initial = await current()
        guard !Task.isCancelled, initial.security.scheduledDriftCheck, let golden = initial.security.goldenBaselineID, !driftRunning else { return nil }
        driftRunning = true
        defer { driftRunning = false }
        let key = "baseline.lastDriftCheck." + golden
        let last = (try? await metadata.metadata(key)).flatMap(Double.init) ?? 0
        guard now.timeIntervalSince1970 - last >= 86400 else { return nil }
        do {
            let base = try await repository.load(golden)
            let settings = await current()
            let enabled = base.sections.keys.filter { id in
                switch id {
                case "posture": return settings.security.postureCheckInterval != nil
                case "startup", "profiles": return settings.security.watchPersistence
                case "listeners": return settings.sampling.backgroundNetworkEnabled
                case "apps": return settings.shows(.installedApps)
                case "homebrew": return settings.shows(.homebrew)
                case "runtimes": return settings.shows(.devEnvironments)
                case "agents": return settings.shows(.agents)
                case "docker": return settings.shows(.docker)
                default: return true
                }
            }
            async let profile = enabled.contains("profiles") ? configurationProfiles(privileged: settings.sampling.privilegedSampling) : nil
            async let btm = enabled.contains("startup") ? backgroundTasks(privileged: settings.sampling.privilegedSampling) : nil
            async let listeners: NetworkPortSnapshot? = enabled.contains("listeners") || enabled.contains("posture")
                ? networkPorts() : nil
            let (profileValue, btmValue, listenerValue) = await (profile, btm, listeners)
            let collectorSettings = await current()
            var currentDocument = try await capture(enabled.map {
                MachineBaselineCollector(id: $0, settings: collectorSettings, listeners: listenerValue, profiles: profileValue, backgroundTasks: btmValue)
            })
            try Task.checkCancellation()
            let latest = await current()
            guard latest.security.scheduledDriftCheck, latest.security.goldenBaselineID == golden else { return nil }
            let skipped = Set(base.sections.keys).subtracting(enabled).sorted()
            for id in skipped { currentDocument.sections[id] = .init(status: .unavailable, error: "Collector disabled in Settings") }
            let diff = BaselineDiff.compare(base, currentDocument)
            try await metadata.setMetadata(key, value: String(now.timeIntervalSince1970))
            guard diff.drift else { return nil }
            var details = diff.sections.mapValues { "added=\($0.added.count),removed=\($0.removed.count),changed=\($0.changed.count)" }
            details["skipped"] = skipped.joined(separator: ",")
            return .make(kind: .driftDetected, timestamp: Date(), subject: base.name, severity: .warning, details: details)
        } catch { return nil /* Retry on the next maintenance pass. */ }
    }
}
