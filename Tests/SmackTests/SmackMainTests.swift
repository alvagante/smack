import AppKit
import Foundation
import Testing
@testable import Smack

@MainActor
@Test func smackMainDiagnosticLinesIncludeExpectedRuntimeKeys() {
    let lines = SmackMain.diagnosticLines()
    #expect(lines.contains("flavor=\(Capabilities.flavor.rawValue)"))
    #expect(lines.contains("sandboxed=\(Capabilities.isSandboxed)"))
    #expect(lines.contains("ownProcess=true"))
    #expect(lines.contains { $0.hasPrefix("pids=") && $0 != "pids=0" })
    #expect(lines.contains { $0.hasPrefix("cpuCores=") && $0 != "cpuCores=0" })
    #expect(lines.contains { $0.hasPrefix("gpu=") })
#if SMACK_APP_STORE
    #expect(lines.contains("ports=0"))
    #expect(lines.contains("helperStatus=unavailable"))
#else
    #expect(lines.contains { $0.hasPrefix("helperMode=") })
#endif
}

@MainActor
@Test func appDelegateHistoryDatabaseURLAndSchedulerLifecycleWorkWithoutUI() throws {
    let tempBase = FileManager.default.temporaryDirectory
        .appendingPathComponent("smack-main-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempBase) }

    let firstURL = try AppDelegate.historyDatabaseURL(in: tempBase)
    let secondURL = try AppDelegate.historyDatabaseURL(in: tempBase)
    #expect(firstURL == secondURL)
    #expect(firstURL.lastPathComponent == "history.sqlite3")
    #expect(FileManager.default.fileExists(atPath: firstURL.deletingLastPathComponent().path))

    let repository = try HistoryRepository(databaseURL: firstURL)
    let delegate = AppDelegate()
    let scheduler = delegate.makeScheduler(
        history: repository,
        settings: CollectionSettings(),
        privilegedClient: PrivilegedSamplingClient()
    )
    _ = scheduler
    delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
}
