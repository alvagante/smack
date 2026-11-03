import Foundation
import Testing
@testable import Smack

private final class StubSecurityHelper: PrivilegedSecurityQuerying, @unchecked Sendable {
    let version: Int
    init(version: Int) { self.version = version }
    func protocolVersion() async -> Int { version }
    func dumpBackgroundTasks() async -> String? { "btm" }
    func listConfigurationProfiles() async -> String? { "profiles" }
}

private actor DiscardingHistoryWriter: HistoryWriting {
    func save(system: SystemSample) async throws {}
    func save(processes: ProcessSnapshot) async throws {}
    func save(events: [ActivityEvent]) async throws {}
    func maintain(settings: CollectionSettings) async throws {}
}

private func monitor(helper: (any PrivilegedSecurityQuerying)?, metadata: MemoryMetadata = MemoryMetadata()) -> SecurityMonitor {
    SecurityMonitor(metadata: metadata, history: HistoryPersistence(writer: DiscardingHistoryWriter()), helper: helper)
}

@Test func securityMonitorQueriesHelperOnlyWhenPrivilegedAndV2() async {
    #expect(await monitor(helper: StubSecurityHelper(version: 2)).backgroundTasks(privileged: true) == "btm")
    #expect(await monitor(helper: StubSecurityHelper(version: 2)).configurationProfiles(privileged: true) == "profiles")
    #expect(await monitor(helper: StubSecurityHelper(version: 2)).backgroundTasks(privileged: false) == nil)
    #expect(await monitor(helper: StubSecurityHelper(version: 1)).configurationProfiles(privileged: true) == nil)
    #expect(await monitor(helper: nil).backgroundTasks(privileged: true) == nil)
}

@Test func securityMonitorPatchesProfileCheckIntoRestoredPosture() async {
    let metadata = MemoryMetadata()
    let stored = monitor(helper: nil, metadata: metadata)
    let old = PostureCheck(id: "config-profiles", status: .unknown, summary: "old", evidence: "")
    await stored.save(PostureSnapshot(timestamp: Date(), checks: [old]))

    let restarted = monitor(helper: nil, metadata: metadata)
    #expect(await restarted.recordProfileCheck(old) == nil, "nothing published or restored yet")
    #expect(await restarted.restoreCache()?.checks.first?.summary == "old")
    let new = PostureCheck(id: "config-profiles", status: .pass, summary: "new", evidence: "")
    #expect(await restarted.recordProfileCheck(new)?.checks.first?.summary == "new")
}

@Test func securityMonitorIgnoresBackgroundTaskDumpsWithoutRecords() {
    #expect(SecurityMonitor.backgroundTaskInventory("helper error") == nil)
    #expect(SecurityMonitor.backgroundTaskInventory("Records for UID 501")?.includesBackgroundTasks == true)
}
