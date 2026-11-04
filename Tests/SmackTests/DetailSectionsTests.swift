import AppKit
import Foundation
import SwiftUI
import SmackIPC
import Testing
@testable import Smack

@Test func pathOriginSeparatesMacOSFromBundledAndUserCode() {
    #expect(PathOrigin(path: "/System/Library/Frameworks/AppKit.framework/AppKit") == .system)
    #expect(PathOrigin(path: "/usr/lib/libSystem.B.dylib") == .system)
    #expect(PathOrigin(path: "/Applications/Slack.app/Contents/Frameworks/Electron Framework.framework/Electron Framework") == .application)
    #expect(PathOrigin(path: "/opt/homebrew/lib/libssl.3.dylib") == .homebrew)
    #expect(PathOrigin(path: "/Users/al/Library/Caches/x.db", home: "/Users/al") == .user)
    #expect(PathOrigin(path: "/private/var/folders/m3/x/T/cache.db") == .temporary)
    #expect(PathOrigin(path: "/Library/Application Support/Vendor/plugin.dylib") == .other)
}

@Test func splitPathKeepsNonPathsWhole() {
    #expect(DetailReadings.splitPath("/usr/lib/libz.dylib") == ("libz.dylib", "/usr/lib"))
    #expect(DetailReadings.splitPath("/etc") == ("etc", "/"))
    #expect(DetailReadings.splitPath("->0x1234").folder == nil)
    #expect(DetailReadings.splitPath("/tmp/").folder == nil)
}

@Test func connectionToneGroupsTCPStates() {
    #expect(ConnectionTone(state: "ESTABLISHED") == .active)
    #expect(ConnectionTone(state: "CONNECTED") == .active)
    #expect(ConnectionTone(state: "LISTEN") == .listening)
    #expect(ConnectionTone(state: "CLOSE_WAIT") == .closing)
    #expect(ConnectionTone(state: "UNCONNECTED") == .idle)
    #expect(DetailReadings.stateTitle("CLOSE_WAIT") == "Close Wait")
    #expect(!DetailReadings.hasRemote("—"))
    #expect(DetailReadings.hasRemote("17.253.144.10:443"))
}

@Test func threadGroupsPutMainFirstThenMostCPUTime() throws {
    let groups = ThreadGroup.grouping([
        ThreadInfo(id: 1, name: nil, state: .waiting, cpuTime: 0.1),
        ThreadInfo(id: 2, name: "worker", state: .running, cpuTime: 2, recentCPU: 0.4, priority: 31),
        ThreadInfo(id: 3, name: "com.apple.main-thread", state: .waiting, cpuTime: 1),
        ThreadInfo(id: 4, name: "worker", state: .uninterruptible, cpuTime: 3, recentCPU: 0.1, priority: 20),
        ThreadInfo(id: 5, name: "io", state: .waiting, cpuTime: 0.5, fixedPolicy: "FIFO")
    ])
    #expect(groups.map(\.name) == ["com.apple.main-thread", "worker", "io", ""])
    let worker = try #require(groups.first { $0.name == "worker" })
    #expect(worker.count == 2 && worker.running == 1 && worker.uninterruptible == 1)
    #expect(worker.cpuTime == 5 && worker.priorities == 20...31)
    #expect(abs((worker.recentCPU ?? 0) - 0.5) < 0.0001)
    #expect(groups.first { $0.name == "io" }?.fixedPolicies == ["FIFO"])
}

@Test func threadGroupsFromNameOnlyRecordsHaveNoReadings() throws {
    let thread = InventoryCollector.thread(from: ThreadRecord(id: 9, name: "main"))
    let group = try #require(ThreadGroup.grouping([thread]).first)
    #expect(thread.state == nil && group.cpuTime == nil && group.recentCPU == nil && group.priorities == nil)
}

@Test func threadRecordMapsSchedulerFields() {
    let thread = InventoryCollector.thread(from: ThreadRecord(id: 1, name: "a", runState: 4, userTime: 1_500_000_000,
                                                              systemTime: 500_000_000, cpuUsage: 250, priority: 47, policy: 4))
    #expect(thread.state == .uninterruptible && thread.cpuTime == 2 && thread.recentCPU == 0.25)
    #expect(thread.priority == 47 && thread.fixedPolicy == "FIFO")
}

@Test func cpuTimeFormatting() {
    #expect(DetailReadings.cpuTime(0.042) == "42 ms")
    #expect(DetailReadings.cpuTime(1.25).hasSuffix(" s"))
}

@Test func environmentAndEntitlementRisks() {
    #expect(DetailReadings.risk(ofVariable: "DYLD_INSERT_LIBRARIES") == .injection)
    #expect(DetailReadings.risk(ofVariable: "GITHUB_TOKEN") == .sensitive)
    #expect(DetailReadings.risk(ofVariable: "PATH") == .normal)
    #expect(DetailReadings.isRiskyEntitlement("com.apple.security.cs.disable-library-validation"))
    #expect(!DetailReadings.isRiskyEntitlement("com.apple.security.app-sandbox"))
    #expect(DetailReadings.entitlementFlag("1") == true)
    #expect(DetailReadings.entitlementFlag("0") == false)
    #expect(DetailReadings.entitlementFlag("(\n  group.x\n)") == nil)
}

@Test func logLevelsAreCountedFromFormattedLines() {
    let lines = ["2026-11-03 10:00:00 [Error] disk full", "2026-11-03 10:00:01 [Default] ok", "2026-11-03 10:00:02 [Error] again", "no tag"]
    let counts = LogLevel.counts(lines)
    #expect(counts[.error] == 2)
    #expect(counts[.default] == 1)
    #expect(counts[.fault] == nil)
    #expect(String(LogLevel.highlighted(lines).characters) == lines.joined(separator: "\n"))
}

@MainActor
@Test func detailPagesRenderEverySectionAtCompactAndWideSizes() async throws {
    let root = try obsTemporaryDirectory()
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let defaults = try #require(UserDefaults(suiteName: "DetailPreview-\(UUID().uuidString)"))
    let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
    let scheduler = CollectionScheduler(
        systemCollector: SystemCollector(), processCollector: ProcessCollector(),
        inventoryCollector: InventoryCollector(), networkPortCollector: NetworkPortCollector(),
        history: history, settings: settings.settings, onSystem: { _ in }, onProcesses: { _ in }
    )
    let store = MonitorStore(settingsStore: settings, history: history, scheduler: scheduler)
    var process = obsProcess(getpid(), name: "SmackTests", path: ProcessInfo.processInfo.arguments.first, app: true)
    process.identity.startTime = try #require(ProcessTerminator.startTime(of: getpid()))
    process.userName = NSUserName()
    let app = ApplicationMetrics(id: "app:smack-tests", name: "Smack Tests", bundleIdentifier: nil,
                                 executablePath: process.executablePath, processes: [process])
    store.processes = ProcessSnapshot(timestamp: Date(), applications: [app], backgroundProcesses: [])

    store.route = .application(app.id)
    #expect(store.routeSubject == "Smack Tests")
    store.route = .process(process.id)
    #expect(store.routeSubject == "SmackTests")

    let sections: [ProcessSection] = [.overview, .history, .files, .connections, .threads, .libraries, .provenance]
        + ProcessInspectionTab.allCases.map { .inspection($0) }
    for width in [560.0, 1_000.0] {
        try await render(ApplicationDetailView(store: store, id: app.id), name: "application-overview", width: width)
        for section in sections {
            store.processDetailViewModel.sectionProcessID = process.id
            store.processDetailViewModel.section = section
            try await render(ProcessDetailView(store: store, id: process.id), name: "process-\(section.title)", width: width)
        }
    }
}

@MainActor
private func render<V: View>(_ content: V, name: String, width: Double) async throws {
    let view = NSHostingView(rootView: content.frame(width: width, height: 760).background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    #expect(view.fittingSize.width <= width + 1, "\(name) at \(Int(width)) overflows")
    if let directory = ProcessInfo.processInfo.environment["SMACK_DETAIL_PREVIEW_DIR"] {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let destination = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try png.write(to: destination.appendingPathComponent("\(name.replacingOccurrences(of: " ", with: "-"))-\(Int(width)).png"))
    }
    window.contentView = nil
}

@Test func threadTableSortsByStateThenCPU() {
    func row(_ name: String, running: Int = 0, blocked: Int = 0, cpu: Double? = nil) -> ThreadTableRow {
        ThreadTableRow(id: name, group: ThreadGroup(name: name, count: 1, running: running, uninterruptible: blocked, cpuTime: cpu))
    }
    let idle = row("idle", cpu: 9), busy = row("busy", running: 1, cpu: 1), io = row("io", blocked: 1), legacy = row("legacy")
    #expect(ThreadTable.compare(.state, busy, io) == .orderedDescending)
    #expect(ThreadTable.compare(.state, io, idle) == .orderedDescending)
    #expect(ThreadTable.compare(.cpuTime, idle, busy) == .orderedDescending)
    #expect(ThreadTable.compare(.cpuTime, legacy, io) == .orderedSame)
    #expect(ThreadTable.compare(.name, row(""), row("a")) == .orderedDescending)
    #expect(ThreadTable.stateTitle(busy.group) == "Running" && ThreadTable.stateTitle(io.group) == "Blocked")
}
