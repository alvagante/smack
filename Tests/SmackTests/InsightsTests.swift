import Foundation
import Testing
@testable import Smack

// MARK: Pure builders

@Test func diskLedgerBucketsInLocalTimeAndRanksPrograms() {
    // UTC+1: local midnight is 23:00 UTC the day before.
    let offset: TimeInterval = 3_600
    let start = Date(timeIntervalSince1970: 86_400 * 10 - offset)          // local day 10, 00:00
    let window = DateInterval(start: start, duration: 2 * 86_400 - 1)        // local days 10 and 11
    let cells = [
        DiskWriteLedger.Cell(name: "a", bucket: 10, bytes: 100),
        DiskWriteLedger.Cell(name: "a", bucket: 11, bytes: 50),
        DiskWriteLedger.Cell(name: "b", bucket: 11, bytes: 400),
        DiskWriteLedger.Cell(name: "c", bucket: 11, bytes: 0),
    ]
    let ledger = DiskWriteLedger.make(cells: cells, window: window, bucket: 86_400, utcOffset: offset, systemTotal: 900, limit: 1)
    #expect(ledger.bucketStarts == [start, start.addingTimeInterval(86_400)])
    #expect(ledger.rows == [DiskWriteLedger.Row(name: "b", total: 400, buckets: [0, 400])])
    #expect(ledger.attributedTotal == 550)
    #expect(ledger.programCount == 2)
    #expect(ledger.systemTotal == 900)
    #expect(abs(ledger.perDay(550) - 275) < 0.01)
}

private func churnRow(_ name: String, path: String?, starts: Int, launchd: Int, lifetime: TimeInterval?) -> ProcessChurnRow {
    ProcessChurnRow(name: name, path: path, starts: starts, launchdStarts: launchd, matchedExits: lifetime == nil ? 0 : starts,
                    averageLifetime: lifetime, shortLived: 0)
}

@Test func churnFlagsOnlyNonSystemLaunchdRestarts() {
    let rows = [
        // On-demand Apple service: frequent, launchd-started, short-lived, but under /System.
        churnRow("mdworker_shared", path: "/System/Library/Frameworks/CoreServices.framework/mdworker_shared", starts: 8_297, launchd: 8_297, lifetime: 88),
        churnRow("agent", path: "/Applications/Vendor.app/Contents/MacOS/agent", starts: 30, launchd: 30, lifetime: 20),
        churnRow("gh", path: "/opt/homebrew/bin/gh", starts: 1_884, launchd: 12, lifetime: 2),
        churnRow("rare", path: "/Applications/Rare.app/rare", starts: 6, launchd: 6, lifetime: 5),
        churnRow("long", path: "/Applications/Long.app/long", starts: 30, launchd: 30, lifetime: 3_600),
        churnRow("unmatched", path: "/Applications/U.app/u", starts: 30, launchd: 30, lifetime: nil),
        churnRow("nopath", path: nil, starts: 30, launchd: 30, lifetime: 20),
    ]
    let classified = ProcessChurn.classify(rows, hours: 24)
    #expect(classified.filter(\.restartsOften).map(\.name) == ["agent"])
    #expect(classified.first?.name == "agent")
    #expect(classified.dropFirst().first?.name == "mdworker_shared")
    // 6 launchd starts over 24 hours is below one per hour.
    #expect(!ProcessChurn.restartsOften(rows[3], hours: 24))
    #expect(ProcessChurn.restartsOften(rows[3], hours: 1))
    #expect(ProcessChurn.classify(rows, hours: 24, limit: 2).count == 2)
}

@Test func destinationsKeepPublicHostsAndFindFirstSightings() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let window = DateInterval(start: now.addingTimeInterval(-86_400), end: now)
    let old = now.addingTimeInterval(-3 * 86_400)
    let recent = now.addingTimeInterval(-600)
    func endpoint(_ program: String, _ value: String, _ seen: Date, _ count: Int = 1) -> DestinationReport.Endpoint {
        DestinationReport.Endpoint(program: program, endpoint: value, firstSeen: seen, connections: count)
    }
    let report = DestinationReport.make(endpoints: [
        endpoint("browser", "8.8.8.8:443", old),
        endpoint("browser", "1.1.1.1:443", recent, 2),
        endpoint("browser", "1.1.1.1:80", recent.addingTimeInterval(-60), 3),
        endpoint("browser", "[2606:4700::1111]:443", recent),
        endpoint("browser", "127.0.0.1:8080", recent),
        endpoint("browser", "10.42.100.10:22", recent),
        endpoint("browser", "[::1]:443", recent),
        endpoint("newtool", "9.9.9.9:443", recent),
        endpoint("lanonly", "192.168.1.5:22", recent),
    ], coverageStart: old, window: window)
    #expect(report.newProgramCount == 1)
    #expect(report.newHostCount == 3)
    #expect(report.programs.map(\.name) == ["newtool", "browser"])
    let browser = try! #require(report.programs.first { $0.name == "browser" })
    #expect(!browser.isNew)
    #expect(browser.knownHostCount == 1)
    let cloudflare = try! #require(browser.newHosts.first { $0.host == "1.1.1.1" })
    #expect(cloudflare.ports == [80, 443])
    #expect(cloudflare.connections == 5)
    #expect(cloudflare.firstSeen == recent.addingTimeInterval(-60))
    #expect(browser.newHosts.contains { $0.host == "2606:4700::1111" })
    #expect(!report.hasShortCoverage)
    #expect(DestinationReport.make(endpoints: [], coverageStart: now.addingTimeInterval(-90_000), window: window).hasShortCoverage)
    #expect(DestinationReport.make(endpoints: [], coverageStart: nil, window: window).hasShortCoverage)
    let limited = DestinationReport.make(endpoints: [endpoint("a", "8.8.8.8:1", recent), endpoint("a", "8.8.4.4:1", recent.addingTimeInterval(1))],
                                         coverageStart: old, window: window, limit: 1)
    #expect(limited.omittedHosts == 1)
    #expect(limited.programs.first?.newHosts.map(\.host) == ["8.8.4.4"])
}

private func program(_ name: String, cpu: Double = 0, memory: Double = 0, disk: Double = 0, wakeups: Double = 0) -> HistoricalProgram {
    HistoricalProgram(name: name, instanceCount: 1, lastSeen: Date(), cpuTotal: cpu, cpuPeak: 0, memoryTotal: memory, memoryPeak: 0,
                      diskBytes: disk, diskPeak: 0, wakeupsTotal: wakeups, wakeupsPeak: 0)
}

@Test func spikeAttributionFollowsEnabledMetrics() {
    let window = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 600)
    let programs = [program("a", cpu: 500, disk: 10, wakeups: 100), program("b", cpu: 1_000, memory: 5_000), program("c", cpu: 0)]
    #expect(SpikeAttribution.measures(for: [.cpu]) == [.cpu, .wakeups])
    #expect(SpikeAttribution.measures(for: [.swapUsedBytes, .diskWriteRate]) == [.memory, .disk, .wakeups])
    let attribution = SpikeAttribution.make(programs: programs, metrics: [.cpu, .networkReceiveRate], window: window,
                                            eventCounts: [.processStarted: 2, .processExited: 1, .listenerOpened: 1])
    let cpu = try! #require(attribution.rankings.first)
    #expect(cpu.measure == .cpu)
    #expect(cpu.entries == [NamedValue(name: "b", value: 100), NamedValue(name: "a", value: 50)])
    #expect(attribution.rankings.last?.entries == [NamedValue(name: "a", value: 10)])
    #expect(attribution.eventCounts == [.processes: 3, .network: 1])
    #expect(attribution.unattributable == [.networkReceiveRate])
}

@Test @MainActor func historyClickZoomStaysInsideTheDomain() {
    let model = HistoryViewModel()
    let start = Date(timeIntervalSince1970: 0)
    let domain = start...start.addingTimeInterval(3_600)
    model.zoom(around: start.addingTimeInterval(60), within: domain)
    #expect(model.zoom == start...start.addingTimeInterval(HistoryViewModel.clickZoom))
    model.zoom = nil
    model.zoom(around: start.addingTimeInterval(1_800), within: domain)
    #expect(model.zoom == start.addingTimeInterval(1_650)...start.addingTimeInterval(1_950))
    let narrow = model.zoom
    model.zoom(around: start.addingTimeInterval(1_700), within: narrow!)
    #expect(model.zoom == narrow)
}

@Test func digestSummarizesTheDay() {
    let window = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 86_400)
    let ledger = DiskWriteLedger.make(cells: [DiskWriteLedger.Cell(name: "writer", bucket: 0, bytes: 2_048)], window: window,
                                      bucket: 3_600, utcOffset: 0, systemTotal: nil)
    let digest = InsightsDigest.make(
        window: window, peakCPU: 87, peakPressure: 1, programs: [program("busy", cpu: 1_440 * 20), program("idle")],
        ledger: ledger, eventCounts: [.listenerOpened: 2, .startupItemAdded: 1, .alertFired: 1],
        destinations: nil, churn: [ProcessChurnRow(name: "agent", path: nil, starts: 1, launchdStarts: 1, matchedExits: 0,
                                                   averageLifetime: nil, shortLived: 0, restartsOften: true)])
    #expect(digest.topCPU == NamedValue(name: "busy", value: 20))
    #expect(digest.topWriter == NamedValue(name: "writer", value: 2_048))
    #expect(digest.usageLine.contains("Peak CPU"))
    #expect(digest.usageLine.contains("warning"))
    #expect(digest.diskLine?.contains("writer") == true)
    #expect(digest.highlights == ["Restarts often: agent", "1 alert fired · 1 startup change · 2 new listeners"])

    let endpoints = [DestinationReport.Endpoint(program: "newtool", endpoint: "9.9.9.9:443", firstSeen: window.end, connections: 1)]
    func withCoverage(_ start: Date) -> InsightsDigest {
        let report = DestinationReport.make(endpoints: endpoints, coverageStart: start, window: window)
        return InsightsDigest.make(window: window, peakCPU: nil, peakPressure: nil, programs: [], ledger: nil, eventCounts: [:],
                                   destinations: report, churn: [])
    }
    #expect(withCoverage(window.start.addingTimeInterval(-2 * 86_400)).newExternalPrograms == ["newtool"])
    // Less than a day of earlier connections: every program would look new, so the digest stays quiet.
    #expect(withCoverage(window.start.addingTimeInterval(-3_600)).newExternalPrograms.isEmpty)
}

// MARK: Repository

private func insightsEvent(_ kind: ActivityEventKind, at time: Double, subject: String, processID: String?, name: String,
                           details: [String: String] = [:]) -> ActivityEvent {
    .make(kind: kind, timestamp: Date(timeIntervalSince1970: time), subject: subject, processID: processID, processName: name,
          severity: .info, details: details, dedupe: "\(time)\(subject)\(processID ?? "")")
}

@Test func repositoryChurnMatchesExitsAndCountsLaunchdStarts() async throws {
    let directory = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("h.sqlite"))
    var events: [ActivityEvent] = []
    for index in 0..<4 {
        let id = "\(100 + index)-\(index)"
        let start = 1_000 + Double(index) * 100
        events.append(insightsEvent(.processStarted, at: start, subject: "job", processID: id, name: "job",
                                    details: ["pid": "\(100 + index)", "parent": index < 3 ? "1" : "50", "path": "/opt/job"]))
        if index < 3 { events.append(insightsEvent(.processExited, at: start + Double(index * 10 + 5), subject: "job", processID: id, name: "job")) }
    }
    events.append(insightsEvent(.processStarted, at: 1_050, subject: "other", processID: "9-9", name: "other", details: ["parent": "1"]))
    events.append(insightsEvent(.processStarted, at: 9_000, subject: "late", processID: "8-8", name: "late"))
    try await repository.save(events: events)
    let rows = try await repository.processChurn(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 5_000))
    #expect(rows.map(\.name) == ["job", "other"])
    let job = rows[0]
    #expect(job.path == "/opt/job")
    #expect(job.starts == 4)
    #expect(job.launchdStarts == 3)
    #expect(job.matchedExits == 3)
    #expect(job.averageLifetime == 15)
    #expect(job.shortLived == 1)
    #expect(rows[1].averageLifetime == nil)
    let counts = try await repository.eventCounts(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 5_000))
    #expect(counts == [.processStarted: 5, .processExited: 3])
}

@Test func repositoryConnectionEndpointsGroupByRemoteAddress() async throws {
    let directory = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("h.sqlite"))
    #expect(try await repository.connectionEndpoints().coverageStart == nil)
    try await repository.save(events: [
        insightsEvent(.connectionOpened, at: 300, subject: "10.0.0.2:5001 → 1.1.1.1:443", processID: nil, name: "curl"),
        insightsEvent(.connectionOpened, at: 200, subject: "10.0.0.2:5000 → 1.1.1.1:443", processID: nil, name: "curl"),
        insightsEvent(.connectionOpened, at: 400, subject: "10.0.0.2:5002 → [2606:4700::1111]:443", processID: nil, name: "curl"),
        insightsEvent(.connectionClosed, at: 100, subject: "10.0.0.2:4000 → 8.8.8.8:443", processID: nil, name: "curl"),
    ])
    let result = try await repository.connectionEndpoints()
    #expect(result.coverageStart == Date(timeIntervalSince1970: 200))
    let sorted = result.endpoints.sorted { $0.endpoint < $1.endpoint }
    #expect(sorted.map(\.endpoint) == ["1.1.1.1:443", "[2606:4700::1111]:443"])
    #expect(sorted[0].connections == 2)
    #expect(sorted[0].firstSeen == Date(timeIntervalSince1970: 200))
}

private func writer(_ name: String, pid: Int32, at time: Double, diskWrite: Double) -> ProcessSnapshot {
    let process = ProcessMetrics(
        identity: ProcessIdentity(pid: pid, startTime: Date(timeIntervalSince1970: 1)),
        name: name, parentPID: 1, bundleIdentifier: nil, executablePath: nil, userName: nil,
        cpuUsage: 5, memoryBytes: 1_000, diskReadRate: 0, diskWriteRate: diskWrite, energyImpact: nil, threadCount: 1, isApplication: false)
    return ProcessSnapshot(timestamp: Date(timeIntervalSince1970: time), applications: [], backgroundProcesses: [process])
}

@Test func repositoryDiskWritesAndProgramsHonorTheWindow() async throws {
    let directory = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("h.sqlite"))
    // Two samples in the first minute of hour 1 and one in hour 2.
    try await repository.save(processes: writer("w", pid: 7, at: 3_600, diskWrite: 100))
    try await repository.save(processes: writer("w", pid: 7, at: 3_630, diskWrite: 300))
    try await repository.save(processes: writer("w", pid: 7, at: 7_200, diskWrite: 10))
    let cells = try await repository.diskWriteCells(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 10_000),
                                                    bucket: 3_600, utcOffset: 0)
    #expect(cells.sorted { $0.bucket < $1.bucket } == [
        DiskWriteLedger.Cell(name: "w", bucket: 1, bytes: 200 * 60),
        DiskWriteLedger.Cell(name: "w", bucket: 2, bytes: 10 * 60),
    ])
    let early = try await repository.programs(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 4_000))
    #expect(early.first?.diskBytes == Double(200 * 60))
    let all = try await repository.programs(from: Date(timeIntervalSince1970: 0))
    #expect(all.first?.diskBytes == Double(210 * 60))
    #expect(try await repository.systemBytesWritten(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 10_000)) == nil)
}

// MARK: Settings and sources

@Test func insightsDigestSettingDefaultsOnPersistsAndFollowsPresets() throws {
    #expect(CollectionSettings().history.showInsightsDigest)
    let legacy = try JSONDecoder().decode(CollectionSettings.self, from: Data(#"{"history":{"retentionDays":3}}"#.utf8))
    #expect(legacy.history.showInsightsDigest, "settings saved before the key keep the card")
    var settings = CollectionSettings()
    settings.history.showInsightsDigest = false
    let decoded = try JSONDecoder().decode(CollectionSettings.self, from: JSONEncoder().encode(settings))
    #expect(!decoded.history.showInsightsDigest)
    var minimal = CollectionSettings()
    PerformancePreset.minimal.apply(to: &minimal)
    #expect(!minimal.history.showInsightsDigest)
    PerformancePreset.light.apply(to: &minimal)
    #expect(minimal.history.showInsightsDigest)
    #expect(PerformancePreset.matching(settings) == nil, "turning the card off under Standard is a custom setup")
}

@Test func insightsSourcesFollowRecordingSettings() {
    var settings = CollectionSettings()
    let defaults = InsightsSources(settings: settings, supportsConnections: true)
    #expect(defaults.processHistory && defaults.processEvents)
    #expect(!defaults.connectionEvents, "connection events are opt-in")
    settings.activity.recordConnectionEvents = true
    #expect(InsightsSources(settings: settings, supportsConnections: true).connectionEvents)
    #expect(!InsightsSources(settings: settings, supportsConnections: false).connectionEvents, "App Store build records no connections")
    settings.activity.recordNetworkEvents = false
    #expect(!InsightsSources(settings: settings, supportsConnections: true).connectionEvents)
    settings.activity.recordActivity = false
    #expect(!InsightsSources(settings: settings, supportsConnections: true).processEvents)
    settings.history.processHistoryTopCount = 50
    #expect(InsightsSources(settings: settings).processHistoryTopCount == 50)
    settings.history.recordProcessHistory = false
    let off = InsightsSources(settings: settings)
    #expect(!off.processHistory && off.processHistoryTopCount == 0)
}

@Test @MainActor func historyAttributionIsCachedAndClearedWithTheWindow() {
    let model = HistoryViewModel()
    let start = Date(timeIntervalSince1970: 0)
    model.zoom = start...start.addingTimeInterval(600)
    model.programs = [program("a", cpu: 600, memory: 60_000)]
    #expect(model.attribution == nil, "no attribution until the window's events are counted")
    model.windowEventCounts = [.processStarted: 1]
    #expect(model.attribution?.rankings.map(\.measure) == [.cpu, .wakeups])
    model.enabledMetrics = [.cpu, .memoryUsedBytes]
    #expect(model.attribution?.rankings.map(\.measure) == [.cpu, .memory, .wakeups])
    model.select(program: "a")
    #expect(model.attribution == nil)
    model.select(program: nil)
    #expect(model.attribution != nil)
    model.zoom = start...start.addingTimeInterval(300)
    #expect(model.windowEventCounts == nil && model.attribution == nil)
}

@Test @MainActor func digestSkipsDestinationsWithoutConnectionEventsAndReloadsWhenSourcesChange() async throws {
    let directory = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try HistoryRepository(databaseURL: directory.appendingPathComponent("h.sqlite"))
    let now = Date()
    try await repository.save(events: [
        insightsEvent(.connectionOpened, at: now.timeIntervalSince1970 - 3 * 86_400, subject: "10.0.0.2:1 → 8.8.8.8:443", processID: nil, name: "old"),
        insightsEvent(.connectionOpened, at: now.timeIntervalSince1970 - 600, subject: "10.0.0.2:2 → 9.9.9.9:443", processID: nil, name: "newtool"),
    ])
    let model = InsightsModel(history: repository)
    var settings = CollectionSettings()
    await model.refreshDigestIfStale(sources: InsightsSources(settings: settings, supportsConnections: true), now: now)
    #expect(model.digest?.newExternalPrograms == [])
    settings.activity.recordConnectionEvents = true
    await model.refreshDigestIfStale(sources: InsightsSources(settings: settings, supportsConnections: true), now: now.addingTimeInterval(1))
    #expect(model.digest?.newExternalPrograms == ["newtool"], "a source change bypasses the five-minute cache")
}
