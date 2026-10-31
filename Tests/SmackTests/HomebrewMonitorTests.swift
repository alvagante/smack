import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Smack

struct HomebrewMonitorTests {
    static let info = #"{"formulae":[{"name":"tart","full_name":"openai/tools/tart","desc":"VM tool","installed":[{"version":"1.0"},{"version":"1.1"}],"pinned":false},{"name":"pinned","full_name":"pinned","desc":null,"installed":[{"version":"2"}],"pinned":true}],"casks":[{"token":"app","full_token":"vendor/apps/app","tap":"vendor/apps","desc":"An app","installed":"3"}]}"#
    static let outdated = #"{"formulae":[{"name":"openai/tools/tart","installed_versions":["1.0"],"current_version":"1.2","pinned":false},{"name":"pinned","current_version":"4","pinned":true}],"casks":[{"name":"app","installed_versions":["3"],"current_version":"4"}]}"#

    static var collector: BrewCollector {
        BrewCollector(run: { executable, args in
            let output: String
            switch args.first {
            case "info": output = info
            case "outdated": output = outdated
            case "services": output = #"[{"name":"tart","status":"started","user":"tester"}]"#
            case "cleanup": output = "Would remove: old archive\nThis operation would free approximately 12MB of disk space."
            case "--prefix": output = "/opt/homebrew\n"
            case "-sk" where executable == "/usr/bin/du": output = "42\t/opt/homebrew/Cellar"
            case "search": output = "vendor/tools/new\nother\n"
            default: return .unavailable("Formulae found in multiple taps:\n  * vendor/tools/tart\n  * openai/tools/tart")
            }
            return .init(status: 0, output: output, error: "")
        })
    }

    @Test func packageIdentitySeparatesKindsAndPreservesTapAndVersions() throws {
        let packages = try BrewCollector.packages(info: Self.info, outdated: Self.outdated)
        let tart = try #require(packages.first { $0.name == "tart" })
        #expect(tart.arguments("upgrade") == ["upgrade", "--formula", "openai/tools/tart"])
        #expect(tart.installedVersion == "1.0, 1.1")
        #expect(tart.availableVersion == "1.2")
        let cask = try #require(packages.first { $0.kind == .cask })
        #expect(cask.arguments("install") == ["install", "--cask", "vendor/apps/app"])
        #expect(cask.availableVersion == "4")
        #expect(Set(packages.map(\.id)).count == 3)
        #expect(packages.first { $0.name == "pinned" }?.pinned == true)
    }

    @Test func detailsIncludeCleanupServicesAndToolStorage() async {
        let snapshot = await Self.collector.collect(executable: "/brew", details: true)
        #expect(snapshot.packages?.count == 3)
        #expect(snapshot.updateCount == 3)
        #expect(snapshot.services?.first?.status == "started")
        #expect(snapshot.cleanup?.contains("12MB") == true)
        #expect(snapshot.managedBytes == 42 * 1024)
        #expect(snapshot.warnings.isEmpty)
    }

    @Test func summaryDoesNotRunDetailCommands() async {
        let collector = BrewCollector(run: { _, args in
            #expect(["info", "outdated"].contains(args.first))
            return .init(status: 0, output: args.first == "info" ? Self.info : Self.outdated, error: "")
        })
        let snapshot = await collector.collect(executable: "/brew", details: false)
        #expect(snapshot.packages?.count == 3)
        #expect(snapshot.services == nil)
        #expect(snapshot.cleanup == nil)
    }

    @Test func unavailableUpdatesPreserveInstalledCountAndNeverReportZeroUpdates() async {
        for failure in [CommandRunner.Result.unavailable("offline"),
                        .init(status: 0, output: "{", error: ""),
                        .init(status: 0, output: Self.outdated, error: "", truncated: true)] {
            let collector = BrewCollector(run: { _, args in
                args.first == "info" ? .init(status: 0, output: Self.info, error: "") : failure
            })
            let snapshot = await collector.collect(executable: "/brew", details: false)
            #expect(snapshot.packages?.count == 3)
            #expect(snapshot.updateCount == nil)
            #expect(!snapshot.warnings.isEmpty)
        }
    }

    @Test func emptyInstallationAndCurrentPackagesReportZero() async throws {
        let empty = BrewCollector(run: { _, _ in .init(status: 0, output: #"{"formulae":[],"casks":[]}"#, error: "") })
        let snapshot = await empty.collect(executable: "/brew", details: false)
        #expect(snapshot.packages?.count == 0)
        #expect(snapshot.updateCount == 0)
        let packages = try BrewCollector.packages(info: Self.info, outdated: #"{"formulae":[],"casks":[]}"#)
        #expect(packages.filter(\.isOutdated).isEmpty)
    }

    @Test func missingPackageDataDoesNotReportAnEmptyInstallation() async {
        let collector = BrewCollector(run: { _, _ in .unavailable("failed") })
        let snapshot = await collector.collect(executable: "/brew", details: false)
        #expect(snapshot.packages == nil)
        #expect(snapshot.updateCount == nil)
    }

    @Test func searchPreservesQualifiedNamesAndExplicitKind() async throws {
        let packages = try await Self.collector.search(executable: "/brew", query: "new", kind: .cask)
        #expect(packages.first?.arguments("install") == ["install", "--cask", "vendor/tools/new"])
    }

    @Test @MainActor func missingBrewHidesTileAndFailureRetainsRetryCommand() async {
        let missing = HomebrewMonitor(collector: Self.collector, locate: { nil })
        await missing.refresh()
        #expect(!missing.installed)
        #expect(missing.snapshot == nil)
        let model = HomebrewMonitor(collector: Self.collector, locate: { "/brew" })
        let action = BrewOperation(title: "Upgrade tart", arguments: ["upgrade", "--formula", "openai/tools/tart"])
        await model.perform(action)
        #expect(model.failed)
        #expect(model.output.contains("Formulae found in multiple taps"))
        #expect(model.operation?.arguments == action.arguments)
        #expect(!model.busy)
        #expect(model.snapshot?.packages?.count == 3)
    }

    @Test @MainActor func pageRendersWithCollectedData() async throws {
        let model = HomebrewMonitor(collector: Self.collector, locate: { "/brew" })
        model.detailsWanted = true
        await model.refresh()
        for width in [900.0, 1400.0] {
            let host = NSHostingView(rootView: HomebrewDetailView(model: model)
                .environment(\.colorScheme, .light)
                .background(Color.white))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 650)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide >= Int(width))
            if width == 1400, let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: "/tmp/smack-homebrew-page.png"))
            }
        }
    }
}
