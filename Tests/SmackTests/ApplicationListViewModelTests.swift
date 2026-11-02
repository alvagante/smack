import Foundation
import Synchronization
import Testing
@testable import Smack

@MainActor
@Test func applicationSortingReversesWhenSelectingActiveColumn() {
    let model = ApplicationListViewModel()
    #expect(model.sort == .cpu)
    #expect(!model.ascending)

    model.toggleSort(.cpu)
    #expect(model.sort == .cpu)
    #expect(model.ascending)
}

@MainActor
@Test func applicationSortingSelectsMetricAndDirection() {
    let model = ApplicationListViewModel()
    model.toggleSort(.energy)
    #expect(model.sort == .energy)
    #expect(!model.ascending)

    model.toggleSort(.name)
    #expect(model.sort == .name)
    #expect(model.ascending)
}

@MainActor
@Test func applicationListScopeFollowsSettingUntilChosen() {
    let model = ApplicationListViewModel()
    #expect(model.effectiveScope(showBackgroundProcesses: false) == .apps)
    #expect(model.effectiveScope(showBackgroundProcesses: true) == .all)
    model.scope = .apps
    #expect(model.effectiveScope(showBackgroundProcesses: true) == .apps)
}

@MainActor
@Test func applicationListKillRequestCapturesEveryProcess() {
    let model = ApplicationListViewModel()
    model.killMessage = "old"
    let app = ApplicationMetrics(id: "a", name: "A", bundleIdentifier: nil, executablePath: nil,
                                 processes: [obsProcess(10, app: true), obsProcess(11)])
    model.requestKill(ApplicationListEntry(application: app, currentUser: "me"))
    #expect(model.killRequest?.targets.map(\.pid) == [10, 11])
    #expect(model.killRequest?.kind == .application)
    #expect(model.killMessage == nil)
}

@Test func applicationListAppsScopeHidesOtherApplicationsAndBackground() {
    let user = ApplicationMetrics(id: "u", name: "User", bundleIdentifier: nil, executablePath: nil, processes: [obsProcess(10, app: true)])
    let agent = ApplicationMetrics(id: "s", name: "Agent", bundleIdentifier: nil, executablePath: nil, processes: [obsProcess(20, app: true)])
    let snapshot = ProcessSnapshot(timestamp: Date(), applications: [user, agent], backgroundProcesses: [obsProcess(30)])

    let apps = ApplicationListReadings.entries(snapshot, scope: .apps, userApplications: [10], currentUser: "me")
    #expect(apps.applications.map(\.id) == ["u"])
    #expect(apps.background.isEmpty)

    let all = ApplicationListReadings.entries(snapshot, scope: .all, userApplications: [10], currentUser: "me")
    #expect(all.applications.map(\.id) == ["u", "s"])
    #expect(all.background.map(\.name) == ["p30"])
    #expect(ApplicationListReadings.scopeCounts(snapshot, userApplications: [10]) == "1 apps · 2 other")
}

@Test func applicationListSortsByRunningTimeLongestFirst() {
    let old = ApplicationListEntry(process: obsProcess(1, name: "old", start: 100), currentUser: "me")
    let new = ApplicationListEntry(process: obsProcess(2, name: "new", start: 500), currentUser: "me")
    #expect(ApplicationListReadings.sorted([new, old], by: .uptime, ascending: false).map(\.name) == ["old", "new"])
    #expect(ApplicationListReadings.sorted([old, new], by: .uptime, ascending: true).map(\.name) == ["new", "old"])
}

@Test func applicationListEntryUsesOldestProcessAndForeignOwner() {
    var main = obsProcess(10, path: "/Applications/A.app/Contents/MacOS/A", app: true, start: 300)
    main.userName = "root"
    let helper = obsProcess(11, start: 200)
    let app = ApplicationMetrics(id: "a", name: "A", bundleIdentifier: "com.example.a", executablePath: main.executablePath, processes: [main, helper])
    let entry = ApplicationListEntry(application: app, currentUser: "me")
    #expect(entry.startTime == Date(timeIntervalSince1970: 200))
    #expect(entry.owner == "root")
    #expect(entry.threads == 2)
    #expect(ApplicationListReadings.matches(entry, query: "11"))
    #expect(ApplicationListReadings.matches(entry, query: "example"))
    #expect(!ApplicationListReadings.matches(entry, query: "1"))
}

@Test func applicationListRunningTimeFormats() {
    let now = Date(timeIntervalSince1970: 100_000)
    #expect(ApplicationListReadings.runningTime(since: now.addingTimeInterval(-30), now: now) == "< 1 m")
    #expect(ApplicationListReadings.runningTime(since: now.addingTimeInterval(-3 * 3600 - 120), now: now) == "3 h 2 m")
    #expect(ApplicationListReadings.runningTime(since: now.addingTimeInterval(60), now: now) == "–")
}

@MainActor
@Test func applicationListActionsColumnFitsTheLookupIcons() {
    #expect(ApplicationListLayout.actionsWidth >= FileLookupLinks.width + 20)
}

@Test func applicationListLayoutDropsSecondaryColumnsWhenNarrow() {
    #expect(ApplicationListLayout(width: 0).columns == [.cpu, .memory, .energy, .uptime])
    #expect(!ApplicationListLayout(width: 900).showsTrend)
    #expect(ApplicationListLayout(width: 1200).columns.contains(.network))
    #expect(ApplicationListLayout(width: 1200).showsTrend)
}

private func signature(_ trust: CodeSignatureInfo.Trust, certificate: String? = nil, team: String? = nil, identifier: String? = nil) -> CodeSignatureInfo {
    CodeSignatureInfo(trust: trust, identifier: identifier, teamIdentifier: team, certificateName: certificate, hardenedRuntime: true, entitlementsSummary: [])
}

@Test func applicationListSignerNamesTheDeveloper() {
    #expect(ApplicationListReadings.signer(nil) == nil)
    #expect(ApplicationListReadings.signer(.unavailable) == nil)
    #expect(ApplicationListReadings.signer(signature(.unsigned))?.tone == .danger)
    #expect(ApplicationListReadings.signer(signature(.adHoc))?.tone == .caution)
    #expect(ApplicationListReadings.signer(signature(.signed, certificate: "Software Signing", identifier: "com.apple.mail"))?.title == "Apple")
    let google = ApplicationListReadings.signer(signature(.signed, certificate: "Developer ID Application: Google LLC (EQHXZ8M8AV)", team: "EQHXZ8M8AV"))
    #expect(google?.title == "Google LLC")
    #expect(google?.tone == .trusted)
    #expect(ApplicationListReadings.signer(signature(.signed, certificate: "Apple Mac OS Application Signing", team: "ABC"))?.title == "Mac App Store")
    #expect(ApplicationListReadings.signer(signature(.signed, certificate: "Apple Development: me@example.com (XYZ)", team: "XYZ"))?.tone == .caution)
    #expect(ApplicationListReadings.developerName(certificate: "no colon") == nil)
}

@Test func applicationListLaunchSourcePrefersStartupItemsThenParents() {
    var context = ApplicationListContext()
    context.startupByPID[50] = StartupItem(id: "login:/A.app", name: "A", detail: "/A.app", category: .loginItems, isEnabled: true, pid: 50, control: .loginItem(path: "/A.app"))
    context.launchdIndex["/usr/local/bin/agent"] = LaunchdMatch(label: "com.example.agent", isDaemon: false)
    let terminal = obsProcess(10, parent: 1, name: "Terminal", app: true)
    let login = obsProcess(11, parent: 10, name: "login")
    let zsh = obsProcess(12, parent: 11, name: "zsh")
    context.processesByPID = [10: terminal, 11: login, 12: zsh]
    context.applicationNames = [10: "Terminal"]

    #expect(ApplicationListReadings.launchSource(of: obsProcess(50, parent: 1, app: true), context: context)?.title == "Login item")
    #expect(ApplicationListReadings.launchSource(of: obsProcess(51, parent: 1, path: "/usr/local/bin/agent"), context: context)?.title == "Launch agent")
    #expect(ApplicationListReadings.launchSource(of: obsProcess(52, parent: 1, app: true), context: context)?.title == "Launch Services")
    #expect(ApplicationListReadings.launchSource(of: obsProcess(53, parent: 1), context: context)?.title == "launchd")
    #expect(ApplicationListReadings.launchSource(of: obsProcess(54, parent: 12, name: "node"), context: context)?.title == "Shell in Terminal")
    #expect(ApplicationListReadings.launchSource(of: obsProcess(55, parent: 10), context: context)?.title == "Terminal")
    #expect(ApplicationListReadings.launchSource(of: obsProcess(56, parent: 999), context: context)?.title == "PID 999")
    #expect(ApplicationListReadings.launchSource(of: obsProcess(57, parent: nil), context: context) == nil)
}

@Test func applicationListPortsAreDistinctPerRowAndUnknownWithoutAScan() {
    var context = ApplicationListContext()
    #expect(context.listeningPorts([ProcessIdentity(pid: 1, startTime: Date())]) == nil)
    #expect(ApplicationListReadings.portsSummary(nil) == "–")
    context.portsByPID = [10: [5173, 3000], 11: [3000, 8080, 9229]]
    let ports = context.listeningPorts([10, 11].map { ProcessIdentity(pid: $0, startTime: Date()) })
    #expect(ports == [3000, 5173, 8080, 9229])
    #expect(ApplicationListReadings.portsSummary(ports) == "3000 5173 +2")
    #expect(ApplicationListReadings.portsSummary([]) == "")
}

@MainActor
@Test func applicationListEnrichmentReadsEachPathOnce() async {
    let reads = Mutex<[String]>([])
    let enrichment = ApplicationListEnrichment { path in
        reads.withLock { $0.append(path) }
        return CodeSignatureInfo(trust: .adHoc, identifier: nil, teamIdentifier: nil, certificateName: nil, hardenedRuntime: false, entitlementsSummary: [])
    }
    enrichment.requestSignature(path: "/a")
    enrichment.requestSignature(path: "/a")
    enrichment.requestSignature(path: "/b")
    enrichment.requestSignature(path: "relative")
    await enrichment.drain()
    #expect(reads.withLock { $0 }.sorted() == ["/a", "/b"])
    #expect(enrichment.signatures["/b"]?.trust == .adHoc)
}
