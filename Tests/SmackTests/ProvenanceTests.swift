import Foundation
import Testing
@testable import Smack

// MARK: Ancestry and origin

@Test func ancestryRunsFromParentToLaunchdAndMarksExitedParents() {
    let launchd = obsProcess(1, parent: 0, name: "launchd")
    let shell = obsProcess(50, parent: 1, name: "zsh")
    let tool = obsProcess(60, parent: 50, name: "tool")
    let all = Dictionary(uniqueKeysWithValues: [launchd, shell, tool].map { ($0.identity.pid, $0) })
    let chain = ProcessProvenanceResolver.ancestry(of: tool, in: all)
    #expect(chain.map(\.name) == ["zsh", "launchd"])

    let orphan = obsProcess(70, parent: 999, name: "orphan")
    let missing = ProcessProvenanceResolver.ancestry(of: orphan, in: [70: orphan])
    #expect(missing.count == 1)
    #expect(missing[0].isExited)
}

@Test func ancestryBreaksCyclesAndHandlesMissingParents() {
    let a = obsProcess(10, parent: 11, name: "a")
    let b = obsProcess(11, parent: 10, name: "b")
    let chain = ProcessProvenanceResolver.ancestry(of: a, in: [10: a, 11: b])
    #expect(chain.map(\.pid) == [11])
    let none = obsProcess(12, parent: nil)
    #expect(ProcessProvenanceResolver.ancestry(of: none, in: [12: none]).isEmpty)
    let hiddenLaunchd = obsProcess(13, parent: 1)
    #expect(ProcessProvenanceResolver.ancestry(of: hiddenLaunchd, in: [13: hiddenLaunchd]).map(\.name) == ["launchd"])
}

@Test func originFollowsTheDocumentedOrder() {
    #expect(ProcessProvenanceResolver.origin(of: obsProcess(1, path: "/Applications/X.app/Contents/MacOS/X", app: true), launchd: nil) == .application)
    let match = LaunchdMatch(label: "com.example.job", isDaemon: true)
    #expect(ProcessProvenanceResolver.origin(of: obsProcess(2, path: "/usr/sbin/d"), launchd: match) == .systemDaemon)
    #expect(ProcessProvenanceResolver.origin(of: obsProcess(3, path: "/usr/sbin/d"), launchd: LaunchdMatch(label: "l", isDaemon: false)) == .userAgent)
    #expect(ProcessProvenanceResolver.origin(of: obsProcess(4, path: "/usr/local/bin/tool"), launchd: nil) == .commandLine)
    #expect(ProcessProvenanceResolver.origin(of: obsProcess(5, path: "/Applications/X.app/Contents/Helper"), launchd: nil) == .unknown)
    #expect(ProcessProvenanceResolver.origin(of: obsProcess(6), launchd: nil) == .unknown)
}

@Test func launchdIndexMapsProgramsToLabelsOncePerInventory() {
    let daemon = StartupItem(id: "launchd:/Library/LaunchDaemons/a.plist", name: "A", detail: "com.example.a", category: .daemons, path: "/Library/LaunchDaemons/a.plist", program: "/usr/local/bin/a", isEnabled: true, control: .readOnly)
    let agent = StartupItem(id: "launchd:/Users/u/Library/LaunchAgents/b.plist", name: "B", detail: "com.example.b", category: .agents, path: "/Users/u/Library/LaunchAgents/b.plist", program: "/usr/local/bin/b", isEnabled: true, control: .readOnly)
    let login = StartupItem(id: "login:/Applications/C.app", name: "C", detail: "x", category: .loginItems, program: "/Applications/C.app", isEnabled: true, control: .readOnly)
    let inventory = StartupInventory(timestamp: Date(), items: [daemon, agent, login], warnings: [], includesBackgroundTasks: true)
    let index = ProcessProvenanceResolver.launchdIndex(from: inventory)
    #expect(index["/usr/local/bin/a"] == LaunchdMatch(label: "com.example.a", isDaemon: true))
    #expect(index["/usr/local/bin/b"] == LaunchdMatch(label: "com.example.b", isDaemon: false))
    #expect(index["/Applications/C.app"] == nil)
}

// MARK: Mach-O, quarantine, signature

@Test func architectureParsesThinFatAndUnknownHeaders() {
    func thin(cpu: UInt32) -> Data {
        var data = Data([0xCF, 0xFA, 0xED, 0xFE])
        withUnsafeBytes(of: cpu.littleEndian) { data.append(contentsOf: $0) }
        return data + Data(count: 8)
    }
    #expect(ProcessProvenanceResolver.architecture(fromHeader: thin(cpu: ProcessProvenanceResolver.cpuTypeARM64)) == "arm64")
    #expect(ProcessProvenanceResolver.architecture(fromHeader: thin(cpu: ProcessProvenanceResolver.cpuTypeX8664)) == "x86_64")

    func be(_ value: UInt32) -> Data { Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]) }
    var fat = be(0xCAFE_BABE) + be(2)
    for cpu in [ProcessProvenanceResolver.cpuTypeX8664, ProcessProvenanceResolver.cpuTypeARM64] {
        fat += be(cpu) + Data(count: 16)
    }
    #expect(ProcessProvenanceResolver.architecture(fromHeader: fat) == "universal (x86_64, arm64)")
    #expect(ProcessProvenanceResolver.architecture(fromHeader: Data("#!/bin/sh\n".utf8)) == nil)
    #expect(ProcessProvenanceResolver.architecture(fromHeader: Data()) == nil)
}

@Test func realExecutablesReportAnArchitectureAndSignature() {
    #expect(ProcessProvenanceResolver.readArchitecture(path: "/bin/ls") != nil)
    #expect(ProcessProvenanceResolver.readArchitecture(path: "/nonexistent/path") == nil)
    let signature = ProcessProvenanceResolver.signature(path: "/bin/ls")
    #expect(signature.trust == .signed)
    #expect(signature.identifier?.isEmpty == false)
    #expect(ProcessProvenanceResolver.signature(path: "/nonexistent/path") == .unavailable)
}

@Test func signatureInfoClassifiesAdHocUnsignedAndHardened() {
    let adHoc = ProcessProvenanceResolver.signatureInfo(from: ["flags": NSNumber(value: ProcessProvenanceResolver.csAdHoc), "identifier": "a.b"])
    #expect(adHoc.trust == .adHoc)
    let unsigned = ProcessProvenanceResolver.signatureInfo(from: [:])
    #expect(unsigned.trust == .unsigned)
    let hardened = ProcessProvenanceResolver.signatureInfo(from: [
        "flags": NSNumber(value: ProcessProvenanceResolver.csRuntime), "identifier": "a.b", "teamid": "TEAM123",
        "entitlements-dict": ["com.apple.security.app-sandbox": true, "com.example.unrelated": true, "com.apple.security.network.client": false],
    ])
    #expect(hardened.trust == .signed)
    #expect(hardened.hardenedRuntime)
    #expect(hardened.teamIdentifier == "TEAM123")
    #expect(hardened.entitlementsSummary == ["com.apple.security.app-sandbox"])
}

@Test func quarantineSummaryShortensTheAttribute() {
    #expect(ProcessProvenanceResolver.quarantineSummary(raw: "0083;5f3a1b2c;Safari;ABC") == "Safari (flags 0083)")
    #expect(ProcessProvenanceResolver.quarantineSummary(raw: "0081;5f3a1b2c;;") == "Quarantined (flags 0081)")
    #expect(ProcessProvenanceResolver.quarantineSummary(raw: "") == "Quarantined")
}

@Test func quarantineAttributeIsReadWhenPresent() throws {
    let directory = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("tool")
    try Data("x".utf8).write(to: file)
    #expect(ProcessProvenanceResolver.readQuarantine(path: file.path) == nil)
    let value = "0083;5f3a1b2c;Safari;ABC"
    #expect(setxattr(file.path, "com.apple.quarantine", value, value.utf8.count, 0, 0) == 0)
    #expect(ProcessProvenanceResolver.readQuarantine(path: file.path) == "Safari (flags 0083)")
}

@Test func translationIsKnownForOurOwnProcess() {
    #expect(ProcessProvenanceResolver.isTranslated(pid: getpid()) != nil)
    #expect(ProcessProvenanceResolver.isTranslated(pid: 999_999) == nil)
}

// MARK: File facts cache

@Test func fileFactsAreCachedByFileIdentityAndBounded() async throws {
    let directory = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let counter = Counter()
    let cache = ProcessFileFactsCache { _ in
        counter.increment()
        return ProcessFileFacts(signature: .unavailable, architecture: nil, quarantine: nil)
    }
    let file = directory.appendingPathComponent("a")
    try Data("one".utf8).write(to: file)
    let now = Date()
    _ = await cache.facts(for: file.path, now: now)
    _ = await cache.facts(for: file.path, now: now.addingTimeInterval(10))
    #expect(counter.value == 1)
    // Expired entries are read again.
    _ = await cache.facts(for: file.path, now: now.addingTimeInterval(ProcessFileFactsCache.ttl + 1))
    #expect(counter.value == 2)
    // A changed file is a new key.
    try Data("changed contents".utf8).write(to: file)
    _ = await cache.facts(for: file.path, now: now.addingTimeInterval(20))
    #expect(counter.value == 3)
    #expect(await cache.facts(for: "/nonexistent/file", now: now) == nil)

    for index in 0..<(ProcessFileFactsCache.capacity + 30) {
        let path = directory.appendingPathComponent("f\(index)")
        try Data("\(index)".utf8).write(to: path)
        _ = await cache.facts(for: path.path, now: now.addingTimeInterval(Double(index)))
    }
    #expect(await cache.count <= ProcessFileFactsCache.capacity)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

// MARK: Knowledge base

@Test func bundledKnowledgeBaseLoadsAndMatchesNamesAndBundles() throws {
    let base = ProcessKnowledgeBase.load()
    #expect(base.entries.count >= 25)
    let entry = try #require(base.match(name: "mdworker_shared", bundleIdentifier: nil))
    #expect(entry.category == "Spotlight")
    #expect(base.match(name: "python3.12", bundleIdentifier: nil)?.title == "Python")
    #expect(base.match(name: "Electron Helper", bundleIdentifier: nil)?.title == "Electron app")
    #expect(base.match(name: "pythonista", bundleIdentifier: nil) == nil)
    #expect(base.match(name: "Whatever", bundleIdentifier: "com.docker.docker")?.title == "Docker Desktop")
    #expect(base.match(name: "zzz-unknown", bundleIdentifier: nil) == nil)
    #expect(entry.safeToQuitDescription == "Do not quit")
}

@Test func missingOrMalformedKnowledgeFileYieldsNoMatches() throws {
    let directory = try obsTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bad = directory.appendingPathComponent("bad.json")
    try Data("{ not json".utf8).write(to: bad)
    let empty = ProcessKnowledgeBase(entries: [])
    #expect(empty.match(name: "mds", bundleIdentifier: nil) == nil)
    // A malformed explicit file falls through to the next candidate instead of crashing.
    _ = ProcessKnowledgeBase.load(bundle: Bundle(for: BundleToken.self), fileURL: bad)
}

private final class BundleToken {}

// MARK: Tree

@Test func treeIsRootedAtLaunchdAndDeduplicatesHelpers() {
    let launchd = obsProcess(1, parent: 0, name: "launchd")
    let app = obsProcess(100, parent: 1, name: "App", app: true)
    let helper = obsProcess(101, parent: 100, name: "App Helper")
    let daemon = obsProcess(200, parent: 1, name: "daemon")
    let tree = ProcessTreeBuilder.build(
        applications: [ApplicationMetrics(id: "a", name: "App", bundleIdentifier: nil, executablePath: nil, processes: [app, helper])],
        background: [launchd, daemon, helper]
    )
    #expect(tree.count == 1)
    #expect(tree[0].title == "launchd")
    #expect(tree[0].children.map(\.title).sorted() == ["App", "daemon"])
    let appNode = tree[0].children.first { $0.title == "App" }
    #expect(appNode?.children.map(\.title) == ["App Helper"])
}

@Test func treeUsesSyntheticNodesForExitedParentsAndHiddenLaunchd() {
    let child = obsProcess(300, parent: 299, name: "child")
    let sibling = obsProcess(301, parent: 299, name: "sibling")
    let hidden = obsProcess(400, parent: 1, name: "viaLaunchd")
    let parentless = obsProcess(500, parent: nil, name: "orphan")
    let tree = ProcessTreeBuilder.build(processes: [child, sibling, hidden, parentless])
    let exited = tree.first { $0.isExitedParent }
    #expect(exited?.children.count == 2)
    #expect(tree.contains { $0.title == "launchd" && $0.process == nil })
    #expect(tree.contains { $0.title == "orphan" })
}

@Test func treeBreaksCyclesAndSelfParents() {
    let a = obsProcess(10, parent: 11, name: "a")
    let b = obsProcess(11, parent: 10, name: "b")
    let selfParent = obsProcess(12, parent: 12, name: "self")
    let tree = ProcessTreeBuilder.build(processes: [a, b, selfParent])
    let rows = ProcessTreeBuilder.flatten(tree, collapsed: [], query: "") { $0.title < $1.title }
    #expect(Set(rows.map(\.node.title)) == ["a", "b", "self"])
    #expect(rows.count == 3)
}

@Test func flattenHonoursCollapseAndSearch() {
    let root = obsProcess(1, parent: 0, name: "launchd")
    let a = obsProcess(2, parent: 1, name: "alpha")
    let b = obsProcess(3, parent: 2, name: "beta")
    let tree = ProcessTreeBuilder.build(processes: [root, a, b])
    let order: (ProcessTreeNode, ProcessTreeNode) -> Bool = { $0.title < $1.title }
    #expect(ProcessTreeBuilder.flatten(tree, collapsed: [], query: "", areInIncreasingOrder: order).map(\.depth) == [0, 1, 2])
    #expect(ProcessTreeBuilder.flatten(tree, collapsed: [a.id], query: "", areInIncreasingOrder: order).count == 2)
    let searched = ProcessTreeBuilder.flatten(tree, collapsed: [a.id], query: "beta", areInIncreasingOrder: order)
    #expect(searched.map(\.node.title) == ["launchd", "alpha", "beta"])
}
