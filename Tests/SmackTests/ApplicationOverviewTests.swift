import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Smack

@Test func bundleURLStopsAtTheFirstAppBundle() {
    #expect(ApplicationReadings.bundleURL(executablePath: "/Applications/Mail.app/Contents/MacOS/Mail")?.path == "/Applications/Mail.app")
    #expect(ApplicationReadings.bundleURL(executablePath: "/Applications/Xcode.app/Contents/Developer/Apps/Simulator.app/Contents/MacOS/Simulator")?.path == "/Applications/Xcode.app")
    #expect(ApplicationReadings.bundleURL(executablePath: "/usr/bin/top") == nil)
}

@Test func applicationLookupFindsOwnerOfAProcess() {
    let helper = obsProcess(11, name: "Helper")
    let snapshot = obsSnapshot([obsProcess(20)], apps: [obsProcess(10), helper])
    #expect(ApplicationReadings.application(containing: helper.id, in: snapshot)?.id == "app")
    #expect(ApplicationReadings.application(containing: obsProcess(20).id, in: snapshot) == nil)
    #expect(ApplicationReadings.application(containing: helper.id, in: nil) == nil)
}

@Test func busiestProcessesSortByCPUThenMemoryAndCountTheRest() {
    var light = obsProcess(3, cpu: 0)
    light.memoryBytes = 500
    let app = ApplicationMetrics(id: "a", name: "A", processes: [obsProcess(1, cpu: 5), light, obsProcess(2, cpu: 150), obsProcess(4, cpu: 0)])
    let (shown, hidden) = ApplicationReadings.busiestProcesses(app, limit: 3)
    #expect(shown.map(\.identity.pid) == [2, 1, 3])
    #expect(hidden == 1)
}

@Test func coresSummaryAndMachineShareTreatOneCoreAsHundredPercent() {
    #expect(ApplicationReadings.coresSummary(cpuUsage: 250, coreCount: 12) == "≈ \(2.5.formatted(.number.precision(.fractionLength(1)))) of 12 cores")
    #expect(ApplicationReadings.coresSummary(cpuUsage: 1_200, coreCount: 16) == "≈ 12 of 16 cores")
    #expect(ApplicationReadings.machineShare(cpuUsage: 300, coreCount: 12) == 25)
    #expect(ApplicationReadings.machineShare(cpuUsage: 300, coreCount: 0) == 0)
}

@Test func gpuValueDistinguishesIdleWarmingAndUnavailable() {
    #expect(ApplicationReadings.gpuValue(nil, status: .available) == Formatting.percent(0))
    #expect(ApplicationReadings.gpuValue(12, status: .available) == Formatting.percent(12))
    #expect(ApplicationReadings.gpuValue(nil, status: .warmingUp) == "Reading…")
    #expect(ApplicationReadings.gpuValue(nil, status: .unavailable) == "Unavailable")
}

@Test func bundleInfoReadsPlistFacts() {
    let info = ApplicationBundleInfo(info: [
        "CFBundleShortVersionString": "16.0", "CFBundleVersion": "3826",
        "LSMinimumSystemVersion": "15.0", "LSApplicationCategoryType": "public.app-category.developer-tools", "LSUIElement": true,
    ], bundlePath: "/Applications/X.app", architectures: [NSBundleExecutableArchitectureARM64, NSBundleExecutableArchitectureX86_64])
    #expect(info.version == "16.0")
    #expect(info.build == "3826")
    #expect(info.category == "Developer Tools")
    #expect(info.architectures == "Universal (Apple silicon, Intel)")
    #expect(info.isAgent)
    #expect(ApplicationReadings.category("com.example.other") == nil)
    #expect(ApplicationReadings.architectures([NSBundleExecutableArchitectureARM64]) == "Apple silicon")
    #expect(ApplicationReadings.architectures([]) == nil)
}

@Test func startTimeAndUsersComeFromAllProcesses() {
    var root = obsProcess(1, start: 50)
    root.userName = "root"
    var user = obsProcess(2, start: 10)
    user.userName = "al"
    let app = ApplicationMetrics(id: "a", name: "A", processes: [root, user, obsProcess(3, start: 90)])
    #expect(ApplicationReadings.startTime(app) == Date(timeIntervalSince1970: 10))
    #expect(ApplicationReadings.users(app) == ["al", "root"])
}

@MainActor
@Test func applicationAndProcessPagesFitCompactAndWideWidths() throws {
    let root = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let defaultsName = "ApplicationLayout-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsName))
    defer { defaults.removePersistentDomain(forName: defaultsName) }
    let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
    let scheduler = CollectionScheduler(
        systemCollector: SystemCollector(),
        processCollector: ProcessSnapshotService(local: ProcessCollector(), privileged: PrivilegedSamplingClient()),
        inventoryCollector: InventoryCollector(), networkPortCollector: NetworkPortCollector(),
        history: history, settings: settings.settings, onSystem: { _ in }, onProcesses: { _ in }
    )
    let store = MonitorStore(settingsStore: settings, history: history, scheduler: scheduler)
    let processes = (0..<24).map { obsProcess(Int32(100 + $0), name: "Helper \($0)", path: "/Applications/Smack Test.app/Contents/MacOS/Helper", cpu: Double($0 * 7)) }
    store.receive(ProcessSnapshot(timestamp: Date(), applications: [
        ApplicationMetrics(id: "app", name: "Smack Test", bundleIdentifier: "com.example.smack-test",
                           executablePath: "/Applications/Smack Test.app/Contents/MacOS/Helper", processes: processes),
    ], backgroundProcesses: []))
    for index in 0..<5 {
        var sample = obsSystem(at: Date().timeIntervalSince1970 - Double(5 - index))
        sample.gpu = GPUSample(utilizationPercent: 30)
        sample.gpuProcesses = [100: 12]
        sample.gpuProcessStatus = .available
        store.receive(sample)
    }
    let pages: [(String, AnyView)] = [
        ("application", AnyView(ApplicationDetailView(store: store, id: "app"))),
        ("process", AnyView(ProcessDetailView(store: store, id: processes[3].id))),
    ]
    for (name, page) in pages {
        for width in [400.0, 720.0, 1300.0] {
            let host = NSHostingView(rootView: page.frame(width: width, height: 900).background(Color(nsColor: .windowBackgroundColor)))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width <= width, "\(name) exceeds \(width)")
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            #expect(!png.isEmpty)
            if let path = ProcessInfo.processInfo.environment["SMACK_LAYOUT_PREVIEW_DIR"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent("\(name)-\(Int(width)).png"))
            }
        }
    }
}
