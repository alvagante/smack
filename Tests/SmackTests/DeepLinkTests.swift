import Foundation
import Testing
@testable import Smack

private func parseLink(_ text: String, flavor: DistributionFlavor = .direct) -> DeepLink {
    DeepLinkParser.parse(URL(string: text)!, resolveProcess: { $0 == 42 ? "42-start" : nil },
        resolveApplication: { $0 == "com.example.live" ? "app-id" : nil }, flavor: flavor)
}

@Test func deepLinkDocumentedRoutes() {
    let routes: [(String, AppRoute)] = [
        ("", .summary), ("summary", .summary), ("cpu", .resource(.cpu)), ("memory", .resource(.memory)),
        ("network", .resource(.network)), ("disk", .resource(.disk)), ("storage", .resource(.storage)),
        ("battery", .resource(.battery)), ("thermal", .resource(.thermal)), ("apps", .applications),
        ("app/com.example.live", .application("app-id")), ("process/42", .process("42-start")),
        ("ports", .networkPorts), ("port/443", .networkPorts), ("docker", .docker), ("homebrew", .homebrew),
        ("dev", .devEnvironments), ("home", .userHome), ("agents", .agents), ("installed", .installedApps),
        ("startup", .startupItems), ("security", .security), ("timeline", .timeline), ("history", .history),
        ("settings", .settings), ("settings/alerts", .settings), ("system", .systemDetails)]
    for (path, route) in routes { #expect(parseLink("smack://" + path).route == route) }
}

@Test func deepLinkEveryParsedFieldIsNavigationOnly() {
    #expect(DeepLinkParser.queryKeys == ["since", "kind", "q"])
    let timeline = parseLink("smack://timeline?since=1h&kind=listenerOpened,processStarted&q=hello%20world")
    #expect(timeline == DeepLink(route: .timeline, filters: ViewFilters(search: "hello world",
        timelineInterval: 3600, timelineKinds: [.listenerOpened, .processStarted])))
    #expect(parseLink("smack://port/443").filters == ViewFilters(port: 443))
    #expect(parseLink("smack://settings/alerts").filters == ViewFilters(settingsPane: .alerts))
    #expect(parseLink("smack://app/com.example.absent").filters == ViewFilters(search: "com.example.absent"))
    #expect(parseLink("smack://process/43") == DeepLink(route: .applications,
        filters: ViewFilters(banner: "Process 43 is not running")))
    #expect(parseLink("smack://timeline?since=30m").filters.timelineInterval == 1800)
    // List every stored output field so additions require reviewing the external surface.
    #expect(Set(Mirror(reflecting: ViewFilters()).children.compactMap(\.label)) ==
        ["search", "port", "timelineInterval", "timelineKinds", "settingsPane", "banner"])
    #expect(Set(Mirror(reflecting: DeepLink()).children.compactMap(\.label)) == ["route", "filters"])
}

@Test(arguments: ["https://cpu", "smack://kill/42", "smack://process/42/kill", "smack://settings/delete",
    "smack://cpu?kill=1", "smack://timeline?mute=1", "smack://timeline?q=a&q=b", "smack://cpu#kill",
    "smack://user@cpu", "smack://cpu:123", "smack://process/0", "smack://process/-1",
    "smack://process/2147483648", "smack://port/65536", "smack://port/0", "smack://port/443junk",
    "smack://timeline?since=nan", "smack://timeline?since=0h", "smack://timeline?since=8d",
    "smack://timeline?kind=unknown", "smack://timeline?kind=processStarted,", "smack://timeline?q",
    "smack://app/com.example%2Fkill", "smack://app/%00", "smack://unknown"])
func deepLinkInvalidInputFallsBackToSummary(_ text: String) {
    #expect(parseLink(text) == DeepLink())
}

@Test func deepLinkEditionGates() {
    for host in ["ports", "port/443", "docker", "homebrew", "dev", "home", "agents", "installed", "startup", "security"] {
        #expect(parseLink("smack://" + host, flavor: .appStore).route == .unavailable("Not available in this edition"))
    }
    #expect(parseLink("smack://settings/alerts", flavor: .appStore).route == .settings)
    #expect(parseLink("smack://timeline", flavor: .appStore).route == .timeline)
}

@Test func sharedProcessPreparationKeepsRuleTrackingIndependent() async {
    let engine = AlertEngine()
    func rule(_ name: String, _ sustain: Double, metric: ProcessAlertMetric = .cpu,
              matcher: ProcessMatcher = ProcessMatcher(anyProcess: true)) -> AlertRule {
        AlertRule(name: name, enabled: true, kind: .processThreshold(metric: metric, matcher: matcher,
            comparison: .greaterThan, value: 80, sustain: sustain, clear: 0))
    }
    let fast = rule("Fast", 5), slow = rule("Slow", 10)
    let memory = rule("Memory", 5, metric: .memoryBytes)
    let absent = rule("Absent", 5, matcher: ProcessMatcher(name: "absent"))
    await engine.update(rules: [fast, slow, memory, absent])
    var process = obsProcess(42, cpu: 95)
    process.memoryBytes = 100
    let processes = [process]
    #expect(await engine.evaluate(processes: obsSnapshot(processes), expectedInterval: 5).isEmpty)
    let first = await engine.evaluate(processes: obsSnapshot(processes, at: 1005), expectedInterval: 5)
    #expect(Set(first.map { $0.rule.id }) == [fast.id, memory.id])
    #expect(first.first?.body.contains("PID 42") == true)
    let second = await engine.evaluate(processes: obsSnapshot(processes, at: 1010), expectedInterval: 5)
    #expect(second.map { $0.rule.id } == [slow.id])
    #expect(await engine.runtime[absent.id]?.state == "No matching process now")
}

@MainActor @Test func navigationAppliesAndReplacesFiltersUsingCachedProcesses() throws {
    let root = try obsTemporaryDirectory()
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let defaults = try #require(UserDefaults(suiteName: "DeepLinkTests-\(UUID().uuidString)"))
    let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
    let scheduler = CollectionScheduler(systemCollector: SystemCollector(),
        processCollector: ProcessSnapshotService(local: ProcessCollector(), privileged: PrivilegedSamplingClient()),
        inventoryCollector: InventoryCollector(), networkPortCollector: NetworkPortCollector(),
        history: history, settings: settings.settings, onSystem: { _ in }, onProcesses: { _ in })
    let store = MonitorStore(settingsStore: settings, history: history, scheduler: scheduler)
    store.receive(obsSnapshot([obsProcess(42)]))
    store.navigate(to: URL(string: "smack://process/42")!)
    #expect(store.route == .process(obsProcess(42).id))
    store.navigate(to: URL(string: "smack://process/43")!)
    #expect(store.route == .applications)
    #expect(store.navigationFilters.banner == "Process 43 is not running")
    let now = Date(timeIntervalSince1970: 10000)
    store.navigate(to: URL(string: "smack://timeline?since=1h&kind=listenerOpened&q=nginx")!, now: now)
    #expect(store.timelineViewModel.window(now: now).duration == 3600)
    #expect(store.timelineViewModel.query == "nginx")
    #expect(store.timelineViewModel.selectedKinds == [.listenerOpened])
    store.navigate(to: URL(string: "smack://timeline")!)
    #expect(store.timelineViewModel.customWindow == nil)
    #expect(store.timelineViewModel.query.isEmpty)
    #expect(store.timelineViewModel.selectedKinds.isEmpty)
    store.navigate(to: URL(string: "smack://settings/alerts")!)
    #expect(store.settingsViewModel.pane == .alerts)
    if Capabilities.flavor == .direct {
        store.navigate(to: URL(string: "smack://port/443")!)
        #expect(store.networkPortsViewModel.port == 443)
        #expect(store.networkPortsViewModel.mode == .listening)
        store.navigate(to: URL(string: "smack://ports")!)
        #expect(store.networkPortsViewModel.port == nil)
    }
    store.navigate(to: URL(string: "smack://settings?kill=42")!)
    #expect(store.route == .summary)
}
