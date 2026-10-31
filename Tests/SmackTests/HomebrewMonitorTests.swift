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
        let snapshot = await Self.collector.collect(executable: "/brew", details: true, section: .cleanup)
        #expect(snapshot.packages?.count == 3)
        #expect(snapshot.updateCount == 3)
        #expect(await Self.collector.collect(executable: "/brew", details: true, section: .services).services?.first?.status == "started")
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

    @Test func packageActionsPreserveKindIdentityAndSafeUninstallDefaults() throws {
        let packages = try BrewCollector.packages(info: Self.info, outdated: Self.outdated)
        for package in packages {
            for action in [BrewPackageAction.uninstall, .reinstall] {
                let operation = action.operation(for: package)
                #expect(operation.arguments == [action.rawValue, package.kind.flag, package.fullName])
                #expect(operation.destructive == (action == .uninstall))
                #expect(operation.explanation?.isEmpty == false)
                #expect(operation.confirmationLabel == action.title)
                #expect(!operation.arguments.contains("--force"))
                #expect(!operation.arguments.contains("--zap"))
                #expect(!operation.arguments.contains("--ignore-dependencies"))
            }
            #expect(BrewPackageAction.upgrade.isAvailable(for: package) == (package.isOutdated && !package.pinned))
            #expect(BrewPackageAction.pin.isAvailable(for: package) == (package.kind == .formula && !package.pinned))
            #expect(BrewPackageAction.unpin.isAvailable(for: package) == (package.kind == .formula && package.pinned))
        }
    }

    @Test func packageDetailsUseReadCommandsAndRejectPartialOutput() async throws {
        let packages = try BrewCollector.packages(info: Self.info, outdated: nil)
        for package in packages {
            for read in BrewPackageRead.allCases {
                let expected = read == .info ? ["info", package.kind.flag, package.fullName]
                    : ["list", "--verbose", package.kind.flag, package.fullName]
                let collector = BrewCollector(run: { executable, arguments in
                    #expect(executable == "/brew")
                    #expect(arguments == expected)
                    return .init(status: 0, output: "Package details", error: "")
                })
                #expect(try await collector.inspect(executable: "/brew", package: package, read: read) == "Package details")
            }
        }
        let package = try #require(packages.first)
        for result in [CommandRunner.Result.unavailable("No such package"),
                       .init(status: 0, output: "partial", error: "", timedOut: true),
                       .init(status: 0, output: "partial", error: "", truncated: true),
                       .init(status: 0, output: "partial", error: "", cancelled: true)] {
            let collector = BrewCollector(run: { _, _ in result })
            await #expect(throws: (any Error).self) {
                try await collector.inspect(executable: "/brew", package: package, read: .info)
            }
        }
    }

    private actor PackageRunner {
        var calls: [[String]] = []
        var continuation: CheckedContinuation<Void, Never>?
        var reading = false

        func run(_ arguments: [String]) async -> CommandRunner.Result {
            calls.append(arguments)
            if arguments == ["list", "--verbose", "--cask", "vendor/apps/app"] {
                reading = true
                await withCheckedContinuation { continuation = $0 }
                return .init(status: 0, output: "/Applications/App.app", error: "")
            }
            let output = arguments.first == "info" ? #"{"formulae":[],"casks":[]}"#
                : arguments.first == "outdated" ? #"{"formulae":[],"casks":[]}"# : "Uninstalled"
            return .init(status: 0, output: output, error: "")
        }

        func finish() { continuation?.resume(); continuation = nil }
    }

    @Test @MainActor func uninstallWaitsForDetailsThenRefreshesInstalledInventory() async throws {
        let runner = PackageRunner()
        let package = try #require(BrewCollector.packages(info: Self.info, outdated: nil).first { $0.kind == .cask })
        let model = HomebrewMonitor(collector: .init(run: { _, args in await runner.run(args) }), locate: { "/brew" })
        let detail = Task { try await model.inspect(package, read: .files) }
        for _ in 0..<100 {
            if await runner.reading { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.loading)
        let uninstall = Task { await model.perform(BrewPackageAction.uninstall.operation(for: package)) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await runner.calls.count == 1)
        await runner.finish()
        #expect(try await detail.value == "/Applications/App.app")
        await uninstall.value
        #expect(await runner.calls == [["list", "--verbose", "--cask", "vendor/apps/app"],
                                      ["uninstall", "--cask", "vendor/apps/app"],
                                      ["outdated", "--json=v2"], ["info", "--json=v2", "--installed"]])
        #expect(model.snapshot?.packages?.isEmpty == true)
        #expect(!model.failed)
        #expect(!model.loading && !model.busy)
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
