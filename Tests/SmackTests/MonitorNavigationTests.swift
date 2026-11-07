import AppKit
import SwiftUI
import Testing
@testable import Smack

@Suite @MainActor struct MonitorNavigationTests {
    @Test func navigationHasEveryTopLevelPageWithoutDuplicates() {
        let sections = MonitorNavigation.sections(settings: CollectionSettings(), hasBattery: true)
        let routes = sections.flatMap(\.routes)
        #expect(Set(routes).count == routes.count)
        #expect(routes.contains(.summary))
        #expect(routes.contains(.systemDetails))
        #expect(routes.contains(.settings))
        #expect(routes.contains(.insights))
        #expect(routes.contains(.resource(.battery)))
        for resource in ResourceKind.allCases { #expect(routes.contains(.resource(resource))) }
        if !Capabilities.isSandboxed {
            for page in SummaryPage.allCases { #expect(routes.contains(page.route)) }
        }
    }

    @Test func navigationHonorsHiddenPagesHardwareAndEdition() {
        var settings = CollectionSettings()
        settings.hiddenPages = SummaryPage.allCases
        let sections = MonitorNavigation.sections(settings: settings, hasBattery: false)
        let routes = sections.flatMap(\.routes)
        #expect(!routes.contains(.resource(.battery)))
        #expect(sections.first { $0.title == "Environment" }?.routes == [.systemDetails])
        #expect(routes.contains(.networkPorts) == Capabilities.supportsNetworkPortInspection)
        #expect(routes.contains(.startupItems) == Capabilities.supportsStartupItems)
        #expect(routes.contains(.security) == Capabilities.supportsPostureChecks)
        #expect(sections.allSatisfy { !$0.routes.isEmpty })
    }

    @Test func sidebarSectionsAreRouteCategories() {
        let sections = MonitorNavigation.sections(settings: CollectionSettings(), hasBattery: true).dropFirst()
        #expect(sections.map(\.title) == RouteCategory.allCases.map(\.title))
        for (section, category) in zip(sections, RouteCategory.allCases) {
            #expect(section.routes.allSatisfy { $0.category == category })
        }
    }

    @Test func eachCategoryHasItsOwnHueAndEachPageItsOwnShade() {
        let colored = RouteCategory.allCases.filter { $0 != .smack }
        for category in colored {
            let tones = category.catalog.indices.map(category.tone)
            #expect(Set(tones.map(\.hue)).count == tones.count, "\(category) repeats a hue")
            #expect(tones.allSatisfy { category.hues.contains($0.hue) })
        }
        for (index, category) in colored.enumerated() {
            for other in colored.dropFirst(index + 1) { #expect(!category.hues.overlaps(other.hues)) }
        }
        #expect(AppRoute.application("app").category == .activity)
        #expect(AppRoute.process("p").category == .activity)
        #expect(AppRoute.summary.category == nil)
    }

    @Test func detailPagesRetainTheirParentSelection() {
        #expect(AppRoute.application("app").sidebarRoute == .applications)
        #expect(AppRoute.process("process").sidebarRoute == .applications)
        #expect(AppRoute.resource(.cpu).sidebarRoute == .resource(.cpu))
        #expect(AppRoute.unavailable("Unsupported").sidebarRoute == nil)
    }

    @Test func groupedShellRendersInBothAppearances() async throws {
        let directory = try obsTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "MonitorNavigationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
        // Keep rendering deterministic and avoid environment discovery in a layout test.
        settings.update { $0.hiddenPages = SummaryPage.allCases }
        let history = try HistoryRepository(databaseURL: directory.appendingPathComponent("history.sqlite"))
        let client = PrivilegedSamplingClient()
        let scheduler = CollectionScheduler(
            systemCollector: SystemCollector(),
            processCollector: ProcessSnapshotService(local: ProcessCollector(), privileged: client),
            inventoryCollector: InventoryCollector(privileged: client),
            networkPortCollector: NetworkPortCollector(privileged: client),
            history: history, settings: settings.settings,
            onSystem: { _ in }, onProcesses: { _ in }, onInventory: { _, _ in }, onNetworkPorts: { _ in }
        )
        let store = MonitorStore(settingsStore: settings, history: history, scheduler: scheduler)
        for index in 0..<30 {
            var sample = obsSystem(at: 1_000 + Double(index), cpu: 18 + Double(index % 10))
            sample.memory.totalBytes = 32 * 1024 * 1024 * 1024
            sample.memory.usedBytes = 18 * 1024 * 1024 * 1024
            sample.volumes = [VolumeSample(name: "Macintosh HD", mountPath: "/", totalBytes: 1_000_000_000_000, availableBytes: 640_000_000_000)]
            sample.battery = BatterySample(chargePercent: 82, isCharging: true, isPresent: true, timeRemaining: nil, health: "Normal", cycleCount: 70)
            store.receive(sample)
        }
        store.receive(obsSnapshot([], apps: [obsProcess(123, name: "Preview", app: true, cpu: 12)]))
        // Recent history, so Insights and the digest render rows instead of empty states.
        let now = Date().timeIntervalSince1970
        for minute in 0..<30 {
            var writer = obsProcess(321, name: "writer", cpu: 8)
            writer.diskWriteRate = Double(1_000_000 * (minute % 5 + 1))
            try await history.save(processes: obsSnapshot([writer], at: now - Double(minute) * 120))
        }
        var events: [ActivityEvent] = []
        for index in 0..<12 {
            let id = "\(500 + index)-\(index)", time = now - 3_000 + Double(index) * 200
            events.append(.make(kind: .processStarted, timestamp: Date(timeIntervalSince1970: time), subject: "agent", processID: id,
                                processName: "agent", severity: .info, details: ["parent": "1", "path": "/Applications/Vendor.app/agent"]))
            events.append(.make(kind: .processExited, timestamp: Date(timeIntervalSince1970: time + 3), subject: "agent", processID: id,
                                processName: "agent", severity: .info))
        }
        events.append(.make(kind: .connectionOpened, timestamp: Date(timeIntervalSince1970: now - 3 * 86_400), subject: "10.0.0.2:5000 → 8.8.8.8:443",
                            processName: "browser", severity: .info))
        events.append(.make(kind: .connectionOpened, timestamp: Date(timeIntervalSince1970: now - 600), subject: "10.0.0.2:5001 → 1.1.1.1:443",
                            processName: "browser", severity: .info))
        try await history.save(events: events)
        let nativeMenuBar = NativeMenuBarStore()
        let output = ProcessInfo.processInfo.environment["SMACK_DESIGN_PREVIEW_DIR"].map { URL(fileURLWithPath: $0) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for dark in [false, true] {
            for width in [900.0, 1440.0] {
                let routes: [AppRoute] = [.summary, .resource(.cpu), .applications, .settings, .resource(.storage), .insights, .history]
                let root = MonitorRootView(store: store, nativeMenuBarStore: nativeMenuBar, onClose: {})
                    .frame(width: width, height: 900)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: root)
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.appearance = window.appearance
                window.contentView = host
                for (index, route) in routes.enumerated() {
                    store.route = route
                    try await Task.sleep(for: .milliseconds(150))
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    #expect(host.fittingSize.width <= width)
                    if let output {
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let data = try #require(bitmap.representation(using: .png, properties: [:]))
                        try data.write(to: output.appendingPathComponent("\(dark ? "dark" : "light")-\(Int(width))-\(index).png"))
                    }
                }
                window.close()
            }
        }
    }
}
