import Foundation
import Testing
@testable import Smack

@MainActor
struct InstalledAppsMonitorTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("smack-apps-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func bundle(_ root: URL, _ path: String, identifier: String, payload: Int = 0) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": "1.2"]
        try info.write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data(repeating: 1, count: payload).write(to: url.appendingPathComponent("Contents/MacOS/binary"))
        return url
    }

    @Test func discoveryReadsBundlesOneFolderDeepAndDedupesSymlinks() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.appendingPathComponent("Applications")
        try bundle(apps, "Alpha.app", identifier: "test.alpha")
        try bundle(apps, "Utilities/Beta.app", identifier: "test.beta")
        try bundle(apps, "Vendor/Deep/Gamma.app", identifier: "test.gamma")
        try bundle(apps, "Alpha.app/Contents/Helpers/Nested.app", identifier: "test.nested")
        let smack = try bundle(apps, "Smack.app", identifier: "test.smack")
        try FileManager.default.createSymbolicLink(at: apps.appendingPathComponent("Alias.app"),
                                                   withDestinationURL: apps.appendingPathComponent("Alpha.app"))

        let collector = InstalledAppsCollector(roots: [apps, root.appendingPathComponent("missing")],
                                               protectedPaths: [smack.resolvingSymlinksInPath().path], useSpotlight: false)
        let snapshot = collector.discover()
        #expect(Set(snapshot.apps.compactMap(\.bundleIdentifier)) == ["test.alpha", "test.beta", "test.smack"])
        #expect(snapshot.apps.count == 3)
        let alpha = try #require(snapshot.apps.first { $0.bundleIdentifier == "test.alpha" })
        #expect(alpha.name == "Alpha")
        #expect(alpha.version == "1.2")
        #expect(alpha.removable)
        #expect(snapshot.apps.first { $0.bundleIdentifier == "test.smack" }?.removable == false)
        #expect(snapshot.volumeUsedFraction != nil)
    }

    @Test func allocatedSizeCountsBundleFiles() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let small = try bundle(root, "Small.app", identifier: "test.small", payload: 10)
        let large = try bundle(root, "Large.app", identifier: "test.large", payload: 2_000_000)
        let smallSize = try #require(InstalledAppsCollector.allocatedSize(of: small))
        let largeSize = try #require(InstalledAppsCollector.allocatedSize(of: large))
        #expect(largeSize >= 2_000_000)
        #expect(largeSize > smallSize)
    }

    @Test func uninstallTrashesRemovableIdleAppsOnly() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let alpha = try bundle(root, "Alpha.app", identifier: "test.alpha", payload: 100)
        let busy = try bundle(root, "Busy.app", identifier: "test.busy")
        let locked = try bundle(root, "Locked.app", identifier: "test.locked")
        var trashed: [String] = []
        let monitor = InstalledAppsMonitor(
            collector: InstalledAppsCollector(roots: [root], protectedPaths: [locked.resolvingSymlinksInPath().path], useSpotlight: false),
            trash: { trashed.append($0.path) },
            running: { [busy.resolvingSymlinksInPath().path] }
        )
        await monitor.refresh()
        #expect(monitor.snapshot?.measured == false)
        #expect(monitor.snapshot?.apps.allSatisfy { $0.sizeBytes == nil } == true)
        await monitor.measure()
        let snapshot = try #require(monitor.snapshot)
        #expect(snapshot.measured)
        #expect(snapshot.apps.allSatisfy { $0.sizeBytes != nil })

        let removed = await monitor.uninstall(Set(snapshot.apps.map(\.id)))
        let alphaPath = alpha.resolvingSymlinksInPath().path
        #expect(removed.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == [alphaPath])
        #expect(trashed.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == [alphaPath])
        #expect(monitor.snapshot?.apps.map(\.name).sorted() == ["Busy", "Locked"])
        #expect(monitor.failed)
        #expect(monitor.message?.contains("Busy: quit the app first.") == true)
        #expect(monitor.message?.contains("Locked: protected or an application alias.") == true)
    }
    @Test func uninstallRechecksRunningAppsBetweenTrashOperations() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try bundle(root, "Alpha.app", identifier: "test.alpha")
        let beta = try bundle(root, "Beta.app", identifier: "test.beta")
        var active: Set<String> = []
        var trashed: [String] = []
        let monitor = InstalledAppsMonitor(
            collector: InstalledAppsCollector(roots: [root], useSpotlight: false),
            trash: { url in
                trashed.append(url.path)
                active.insert(beta.resolvingSymlinksInPath().path)
            },
            running: { active }
        )
        await monitor.refresh()
        let ids = try #require(monitor.snapshot?.apps.map(\.id))
        let removed = await monitor.uninstall(Set(ids))
        #expect(removed.count == 1)
        #expect(trashed.count == 1)
        #expect(monitor.snapshot?.apps.map(\.name) == ["Beta"])
        #expect(monitor.message?.contains("Beta: quit the app first.") == true)
    }

    @Test func aliasWithoutItsTargetInDiscoveryIsNotUninstallable() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try bundle(root, "Outside/Target.app", identifier: "test.target")
        let apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: apps.appendingPathComponent("Alias.app"), withDestinationURL: target)
        let snapshot = InstalledAppsCollector(roots: [apps], useSpotlight: false).discover()
        #expect(snapshot.apps.count == 1)
        #expect(snapshot.apps.first?.removable == false)
    }

    @Test func discoveryReusesSizesUntilBundleChangesAndCancelledSizingDoesNotPublish() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try bundle(root, "Alpha.app", identifier: "test.alpha", payload: 100)
        let model = InstalledAppsMonitor(collector: .init(roots: [root], useSpotlight: false))
        await model.refresh()
        #expect(model.snapshot?.apps.first?.sizeBytes == nil)
        await model.measure()
        let size = try #require(model.snapshot?.apps.first?.sizeBytes)
        await model.refresh()
        #expect(model.snapshot?.apps.first?.sizeBytes == size)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: app.path)
        await model.refresh()
        #expect(model.snapshot?.apps.first?.sizeBytes == nil)
        let sizing = Task { await model.measure() }
        sizing.cancel()
        await sizing.value
        #expect(model.snapshot?.apps.first?.sizeBytes == nil)
        #expect(!model.measuring)
    }

}
