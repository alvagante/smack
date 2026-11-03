import AppKit
import Foundation
import SwiftUI
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

@Test func threadNamesPutMainFirstAndUnnamedLast() {
    let names = DetailReadings.threadNames([nil, "worker", "com.apple.main-thread", "worker", nil, "io"])
    #expect(names.map(\.name) == ["com.apple.main-thread", "worker", "io", ""])
    #expect(names.map(\.count) == [1, 2, 1, 2])
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
