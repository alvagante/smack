import Foundation
import Testing
import SmackIPC
import Synchronization
@testable import Smack

private func projectFixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("smack-project-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func put(_ root: URL, _ path: String, _ content: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
}

@Test func projectResolverGitWorktreePackedDetachedAndInvalidation() async throws {
    let root = try projectFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try put(root, "repo/.git/HEAD", "ref: refs/heads/main\n")
    try put(root, "repo/.git/packed-refs", "abcdef1234567890 refs/heads/main\n")
    try put(root, "repo/package.json", #"{"name":"test-server"}"#)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("repo/src"), withIntermediateDirectories: true)
    let resolver = ProjectResolver(home: root.path)
    let context = try #require(await resolver.context(forDirectory: root.appendingPathComponent("repo/src").path))
    #expect(context.root == root.appendingPathComponent("repo").path)
    #expect(context.name == "test-server" && context.kind == .node)
    #expect(context.git == GitHead(branch: "main", commit: "abcdef123456", isWorktree: false))
    try put(root, "repo/.git/HEAD", "1234567890abcdef\n")
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: root.appendingPathComponent("repo/.git/HEAD").path)
    #expect(await resolver.context(forDirectory: root.appendingPathComponent("repo/src").path)?.git?.commit == "1234567890ab")
    try put(root, "worktree/.git", "gitdir: ../repo/.git/worktrees/one\n")
    try put(root, "repo/.git/worktrees/one/HEAD", "ref: refs/heads/main\n")
    try put(root, "repo/.git/worktrees/one/commondir", "../..\n")
    let worktree = await resolver.context(forDirectory: root.appendingPathComponent("worktree").path)
    #expect(worktree?.git == GitHead(branch: "main", commit: "abcdef123456", isWorktree: true))
}

@Test func projectResolverManifestsBoundsHomeAndLRU() async throws {
    let root = try projectFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixtures: [(String, ProjectKind, String, String?)] = [
        ("package.json", .node, #"{"name":"node-project"}"#, "node-project"),
        ("pyproject.toml", .python, "[tool.other]\nname = 'wrong'\n[project]\nname = 'python-project'\n", "python-project"),
        ("Cargo.toml", .rust, "[package]\nname = \"rust-project\"\n", "rust-project"),
        ("go.mod", .go, "module example.org/server\n", "example.org/server"),
        ("Gemfile", .ruby, "", nil), ("pom.xml", .java, "", nil),
        ("composer.json", .php, #"{"name":"vendor/php"}"#, "vendor/php"),
        ("Package.swift", .swift, "", nil), ("mix.exs", .elixir, "", nil),
        ("app.csproj", .dotnet, "", nil), ("compose.yaml", .compose, "", nil)]
    let resolver = ProjectResolver(home: root.path)
    for (index, fixture) in fixtures.enumerated() {
        let path = "project\(index)"
        try put(root, path + "/" + fixture.0, fixture.2)
        let result = await resolver.context(forDirectory: root.appendingPathComponent(path).path)
        #expect(result?.kind == fixture.1)
        #expect(result?.name == fixture.3 ?? path)
    }
    try put(root, "big/package.json", String(repeating: "x", count: 262_145))
    #expect(await resolver.context(forDirectory: root.appendingPathComponent("big").path)?.name == "big")
    try put(root, ".git/HEAD", "abcdef\n")
    let stopped = ProjectResolver(home: root.appendingPathComponent("big").path)
    #expect(await stopped.context(forDirectory: root.appendingPathComponent("big").path)?.git == nil)
    #expect(await resolver.context(forDirectory: "/") == nil)
    for index in 0..<514 {
        let dir = root.appendingPathComponent("cache\(index)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = await resolver.context(forDirectory: dir.path)
    }
    #expect(await resolver.cachedDirectoryCount == 512)
}

private func devProcess(_ pid: Int32, parent: Int32? = nil) -> ProcessMetrics {
    ProcessMetrics(identity: ProcessIdentity(pid: pid, startTime: Date(timeIntervalSince1970: 100)),
        name: "node", parentPID: parent, cpuUsage: 0, memoryBytes: 0, diskReadRate: 0, diskWriteRate: 0,
        threadCount: 1, isApplication: false)
}

@Test func devServerGroupingFilteringUnknownAndContainerMapping() async throws {
    let root = try projectFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try put(root, "package.json", #"{"name":"dev-test"}"#)
    let path = root.path
    let collector = DevServerCollector(workingDirectory: { $0.pid == 4 ? nil : path })
    var processes = [devProcess(1), devProcess(2, parent: 1), devProcess(3), devProcess(4)]
    processes[2].name = "com.docker.backend"
    var sockets = [
        SocketRecord(owner: .init(pid: 2, name: "node", userName: "test"), descriptor: 1, localAddress: "127.0.0.1:3000", remoteAddress: "", state: "LISTEN"),
        SocketRecord(owner: .init(pid: 1, name: "node", userName: "test"), descriptor: 2, localAddress: "127.0.0.1:3001", remoteAddress: "", state: "LISTEN"),
        SocketRecord(owner: .init(pid: 3, name: "com.docker.backend", userName: "root"), descriptor: 3, localAddress: "0.0.0.0:8080", remoteAddress: "", state: "LISTEN"),
        SocketRecord(owner: .init(pid: 4, name: "unknown", userName: "test"), descriptor: 4, localAddress: "127.0.0.1:9000", remoteAddress: "", state: "LISTEN")]
    let container = try JSONDecoder().decode(DockerContainer.self, from: Data("""
        {"id":"abc","name":"/web","image":"web","state":"running","status":"Up","project":"demo",
        "composeWorkingDirectory":"\(path)","ports":{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"8080"}]}}
        """.utf8))
    let snapshot = ProcessSnapshot(timestamp: Date(), applications: [], backgroundProcesses: processes)
    var rows = await collector.collect(ports: NetworkPortCollector.snapshot(from: sockets), processes: snapshot, containers: [container], showSystem: false)
    #expect(rows.count == 3)
    #expect(rows.first { $0.process.pid == 1 }?.ports.count == 2)
    #expect(rows.first { $0.process.pid == 4 }?.project == nil)
    #expect(rows.first { $0.container != nil }?.container?.composeProject == "demo")
    #expect(rows.first { $0.container != nil }?.project?.name == "dev-test")
    sockets.append(.init(owner: .init(pid: 50, name: "system", userName: "root"), descriptor: 5,
        localAddress: "0.0.0.0:22", remoteAddress: "", state: "LISTEN"))
    rows = await collector.collect(ports: NetworkPortCollector.snapshot(from: sockets), processes: snapshot, containers: [], showSystem: false)
    #expect(!rows.contains { $0.process.pid == 50 })
    rows = await collector.collect(ports: NetworkPortCollector.snapshot(from: sockets), processes: snapshot, containers: [], showSystem: true)
    #expect(rows.contains { $0.process.pid == 50 && $0.project == nil })
    #expect(DevServerCollector.engineNames == ["com.docker.backend", "vpnkit-bridge", "OrbStack Helper", "limactl", "gvproxy", "qemu-system-aarch64"])
}

@Test func devServerRoutesProtocolAndSettings() throws {
    #expect(DeepLinkParser.parse(URL(string: "smack://devservers")!).route == .devServers)
    #expect(DeepLinkParser.parse(URL(string: "smack://devservers")!, flavor: .appStore).route == .unavailable("Not available in this edition"))
    #expect(ControlProtocol.supports(1) && ControlProtocol.supports(2) && !ControlProtocol.supports(3))
    try ControlRequest(op: "devservers").validate()
    try ControlRequest(op: "who", port: 8080).validate()
    #expect(throws: (any Error).self) { try ControlRequest(op: "who").validate() }
    var settings = try JSONDecoder().decode(CollectionSettings.self, from: Data("{}".utf8))
    #expect(settings.terminalApp == "com.apple.Terminal" && settings.editorApp == nil && !settings.devServersShowSystem)
    settings.editorApp = "dev.zed.Zed"; settings.devServersShowSystem = true; settings.backgroundDevServersEnabled = true
    #expect(try JSONDecoder().decode(CollectionSettings.self, from: JSONEncoder().encode(settings)) == settings)
}

@Test func devServerWarmCollectionMeasurementAndIdentityCache() async throws {
    let root = try projectFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try put(root, "package.json", #"{"name":"benchmark"}"#)
    let path = root.path
    let collector = DevServerCollector(workingDirectory: { _ in path })
    let processes = (100..<200).map { devProcess(Int32($0)) }
    let sockets = processes.enumerated().map { index, process in
        SocketRecord(owner: .init(pid: process.identity.pid, name: "node", userName: "test"),
            descriptor: 1, localAddress: "127.0.0.1:\(3000 + index)", remoteAddress: "", state: "LISTEN")
    }
    let ports = NetworkPortCollector.snapshot(from: sockets)
    let snapshot = ProcessSnapshot(timestamp: Date(), applications: [], backgroundProcesses: processes)
    let now = Date()
    _ = await collector.collect(ports: ports, processes: snapshot, containers: [], showSystem: false, now: now)
    var elapsed: [Double] = []
    for _ in 0..<50 {
        let start = ContinuousClock.now
        let rows = await collector.collect(ports: ports, processes: snapshot, containers: [], showSystem: false, now: now)
        elapsed.append(Double(start.duration(to: .now).components.attoseconds) / 1e15)
        #expect(rows.count == 100)
    }
    print("Dev server warm 100 listeners p95 milliseconds: \(elapsed.sorted()[47])")
    if ProcessInfo.processInfo.environment["SMACK_PERFORMANCE_BUDGETS"] == "1" {
        #expect(elapsed.sorted()[47] < 10)
    }
}

@Test func devServerDirectoryCacheTracksIdentityAndTTL() async throws {
    let calls = Mutex(0)
    let collector = DevServerCollector(workingDirectory: { _ in calls.withLock { $0 += 1 }; return nil })
    let port = NetworkPortCollector.snapshot(from: [
        SocketRecord(owner: .init(pid: 100, name: "node", userName: "test"), descriptor: 1,
            localAddress: "127.0.0.1:3000", remoteAddress: "", state: "LISTEN")])
    let now = Date()
    var snapshot = ProcessSnapshot(timestamp: now, applications: [], backgroundProcesses: [devProcess(100)])
    for _ in 0..<2 { _ = await collector.collect(ports: port, processes: snapshot, containers: [], showSystem: false, now: now) }
    #expect(calls.withLock { $0 } == 1)
    snapshot.backgroundProcesses[0].identity.startTime = now
    _ = await collector.collect(ports: port, processes: snapshot, containers: [], showSystem: false, now: now)
    #expect(calls.withLock { $0 } == 2)
    _ = await collector.collect(ports: port, processes: snapshot, containers: [], showSystem: false, now: now.addingTimeInterval(31))
    #expect(calls.withLock { $0 } == 3)
}

@Test func devServerAppleSignatureFiltering() async {
    var process = devProcess(100)
    process.executablePath = "/example/signed"
    let snapshot = ProcessSnapshot(timestamp: Date(), applications: [], backgroundProcesses: [process])
    let ports = NetworkPortCollector.snapshot(from: [
        SocketRecord(owner: .init(pid: 100, name: "apple", userName: "test"), descriptor: 1,
            localAddress: "127.0.0.1:3000", remoteAddress: "", state: "LISTEN")])
    let collector = DevServerCollector(isAppleSigned: { $0 == "/example/signed" }, workingDirectory: { _ in nil })
    #expect(await collector.collect(ports: ports, processes: snapshot, containers: [], showSystem: false).isEmpty)
    #expect(await collector.collect(ports: ports, processes: snapshot, containers: [], showSystem: true).count == 1)
}
