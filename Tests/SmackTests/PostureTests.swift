import Foundation
import SQLite3
import Testing
import Synchronization
@testable import Smack

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("smack-security-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func xprotectAgeCoverageAndFutureDateFixtures() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    for (days, status): (Double, PostureStatus) in [(0, .pass), (29, .pass), (30, .warn), (89, .warn), (90, .fail)] {
        #expect(PostureParser.xprotect([("1", now), ("2", now.addingTimeInterval(-days * 86400))], expectedCount: 2, now: now).status == status)
    }
    #expect(PostureParser.xprotect([], expectedCount: 2, now: now).status == .unknown)
    #expect(PostureParser.xprotect([("1", now)], expectedCount: 2, now: now).status == .unknown)
    #expect(PostureParser.xprotect([("", now)], expectedCount: 1, now: now).status == .unknown)
    #expect(PostureParser.xprotect([("1", now.addingTimeInterval(1))], expectedCount: 1, now: now).status == .unknown)
}

@Test func postureToolFixturesAndFailures() {
    let fixtures: [(String, String, PostureStatus)] = [
        ("sip", "System Integrity Protection status: enabled.", .pass),
        ("sip", "System Integrity Protection status: disabled.", .fail),
        ("sip", "System Integrity Protection status: unknown (Custom Configuration).", .warn),
        ("authenticated-root", "Authenticated Root status: enabled", .pass),
        ("authenticated-root", "Authenticated Root status: disabled", .fail),
        ("filevault", "FileVault is On.", .pass), ("filevault", "FileVault is Off.", .fail),
        ("filevault", "Encryption in progress: Percent completed = 20", .warn),
        ("gatekeeper", "assessments enabled", .pass), ("gatekeeper", "assessments disabled", .fail),
        ("firewall", "Firewall is enabled. (State = 1)", .pass), ("firewall", "Firewall is disabled. (State = 0)", .fail),
        ("firewall-stealth", "Stealth mode enabled", .pass), ("firewall-stealth", "Stealth mode disabled", .warn),
        ("mdm", "Enrolled via DEP: No\nMDM enrollment: No", .pass),
        ("system-extensions", "0 extension(s)", .pass)]
    for (id, output, status) in fixtures {
        #expect(PostureParser.command(id, .init(status: 0, output: output, error: "")).status == status)
        #expect(PostureParser.command(id, .init(status: 1, output: output, error: "denied")).status == .unknown)
        #expect(PostureParser.command(id, .init(status: 0, output: output, error: "", timedOut: true)).status == .unknown)
    }
    for id in PostureParser.ids {
        let result = PostureParser.command(id, .init(status: 0, output: String(repeating: "?", count: 6000), error: ""))
        #expect(result.status == .unknown && result.reason != nil && result.evidence.count <= 4096)
    }
}

@Test func posturePreferenceFixturesDoNotInventDefaults() {
    #expect(PostureParser.preferences("auto-update", nil).status == .unknown)
    #expect(PostureParser.preferences("guest", [:]).status == .unknown)
    #expect(PostureParser.preferences("lockdown", ["LDMGlobalEnabled": false]).status == .pass)
    #expect(PostureParser.preferences("auto-update", ["AutomaticCheckEnabled": false]).status == .fail)
    #expect(PostureParser.preferences("auto-update", ["AutomaticCheckEnabled": true]).status == .warn)
    #expect(PostureParser.preferences("auto-update", ["AutomaticCheckEnabled": true, "CriticalUpdateInstall": true, "AutomaticallyInstallMacOSUpdates": true]).status == .pass)
    #expect(PostureParser.preferences("auto-login", ["autoLoginUser": "fixture"]).status == .fail)
    #expect(PostureParser.preferences("guest", ["GuestEnabled": true]).status == .warn)
}

@Test func postureDiffPersistsBaselineAndMatchesRegressionTemplate() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let history = try HistoryRepository(databaseURL: url)
    let old = PostureSnapshot(timestamp: .now, checks: [.init(id: "sip", status: .pass, summary: "Enabled", evidence: "fixture")])
    #expect(old.changes(from: nil).isEmpty)
    try await history.setMetadata(PostureSnapshot.metadataKey, value: String(decoding: JSONEncoder().encode(old), as: UTF8.self))
    let reopened = try HistoryRepository(databaseURL: url)
    let text = try #require(await reopened.metadata(PostureSnapshot.metadataKey))
    let baseline = try JSONDecoder().decode(PostureSnapshot.self, from: Data(text.utf8))
    var new = old; new.timestamp = old.timestamp.addingTimeInterval(10); new.checks[0].status = .fail
    let event = try #require(new.changes(from: baseline).first)
    #expect(event.details["regression"] == "true" && event.details["old"] == "pass" && event.details["new"] == "fail")
    let engine = AlertEngine()
    var rule = try #require(AlertRule.templates.first { $0.name == "Posture regression" }); rule.enabled = true
    await engine.update(rules: [rule])
    #expect(await engine.evaluate(events: [event]).count == 1)
    new.checks[0] = .unknown("sip", "permission denied")
    #expect(new.changes(from: baseline).first?.details["regression"] == "false")
    #expect(new.changes(from: baseline).first?.severity == .info)
}

@Test func postureTCCSchemaAndAccessFixtures() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("TCC.db").path
    #expect(PostureParser.tcc("tcc-user", path: path).status == .unknown)
    #expect(!FileManager.default.fileExists(atPath: path))
    var db: OpaquePointer?
    #expect(sqlite3_open(path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "CREATE TABLE access(service TEXT,client TEXT,auth_value INTEGER,last_modified INTEGER); INSERT INTO access VALUES('kTCCServiceCamera','fixture',2,42)", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let check = PostureParser.tcc("tcc-user", path: path)
    #expect(check.status == .pass && check.evidence.contains("fixture auth=2 modified=42"))
    #expect(sqlite3_open(path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "ALTER TABLE access RENAME COLUMN auth_value TO allowed", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    #expect(PostureParser.tcc("tcc-user", path: path).reason == "Unsupported TCC schema or access denied")
}

@Test func boundedPersistenceReadsRejectLinksLargeAndSpecialFiles() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("fixture")
    try Data("fixture".utf8).write(to: file)
    #expect(BoundedFile.read(file.path) == Data("fixture".utf8))
    #expect(BoundedFile.read(file.path, limit: 3) == nil)
    let link = directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(BoundedFile.read(link.path) == nil)
    #expect(BoundedFile.read(directory.path) == nil)
    #expect(BoundedFile.read("/dev/zero") == nil)
}

@MainActor @Test func watcherFiltersAndMissingHelperNeverPrompt() async {
    #expect(PersistenceWatcher.relevant("/Library/LaunchDaemons/fixture.plist"))
    #expect(PersistenceWatcher.relevant("/private/etc/hosts"))
    #expect(!PersistenceWatcher.relevant("/Library/Preferences/unrelated.plist"))
    #expect(PersistenceWatcher.relevant(FileManager.default.homeDirectoryForCurrentUser.path + "/Library"))
    let helper = PrivilegedSamplingClient()
    #expect(await helper.protocolVersion() == 0)
    #expect(await helper.dumpBackgroundTasks() == nil)
    #expect(await helper.listConfigurationProfiles() == nil)
}

@Test func persistenceLaunchdDeletionRecreationAndIncompleteRecovery() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let agents = root.appendingPathComponent("agents")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    let path = agents.appendingPathComponent("fixture.plist")
    let broken = agents.appendingPathComponent("broken.plist")
    let data = try PropertyListSerialization.data(fromPropertyList: ["Label": "fixture", "Program": "/usr/bin/true"], format: .xml, options: 0)
    try data.write(to: path)
    let scanner = PersistenceScanner(files: [], directory: { $0 == .userAgents ? agents.path : root.appendingPathComponent("absent").path },
                                     overrides: { _ in .init(status: 0, output: "disabled services = {}", error: "") })
    #expect(await scanner.scan(metadata: history, enrich: false).1.isEmpty)
    try Data("broken".utf8).write(to: broken)
    let (partial, appeared) = await scanner.scan(metadata: history, enrich: false)
    #expect(partial?.includedCategories.contains(.agents) == false)
    #expect(appeared.map(\.subject) == [broken.path] && appeared.first?.details["change"] == "added")
    try FileManager.default.removeItem(at: broken)
    let vanished = await scanner.scan(metadata: history, enrich: false).1
    #expect(vanished.map(\.subject) == [broken.path] && vanished.first?.details["change"] == "removed")
    try FileManager.default.removeItem(at: path)
    let removed = await scanner.scan(metadata: history, enrich: false).1.filter { $0.subject == path.path }
    #expect(removed.count == 1 && removed.first?.details["change"] == "removed")
    #expect(removed.first?.details["new"] == "absent")
    #expect(await scanner.scan(metadata: history, enrich: false).1.isEmpty)
    try data.write(to: path)
    let recreated = await scanner.scan(metadata: history, enrich: false).1.filter { $0.subject == path.path }
    #expect(recreated.count == 1 && recreated.first?.details["change"] == "added")
}

// Uninstallers can leave `{}` plists without a Label (seen with Google Keystone). launchd ignores
// them, so they must not keep the category incomplete and the published inventory empty.
@Test func persistenceLabelLessPlistsKeepCoverageAndNoCoverageIsNotPublished() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let agents = root.appendingPathComponent("agents"), daemons = root.appendingPathComponent("daemons")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: daemons, withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["Label": "fixture", "Program": "/usr/bin/true"], format: .xml, options: 0)
        .write(to: agents.appendingPathComponent("fixture.plist"))
    try Data("{\n}\n".utf8).write(to: agents.appendingPathComponent("leftover.plist"))
    try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0)
        .write(to: daemons.appendingPathComponent("leftover.plist"))
    let scanner = PersistenceScanner(files: [], directory: { $0 == .globalDaemons ? daemons.path : $0 == .userAgents ? agents.path : root.appendingPathComponent("absent").path },
                                     overrides: { _ in .init(status: 0, output: "disabled services = {}", error: "") })
    let inventory = await scanner.scan(metadata: history, enrich: false).0
    #expect(inventory?.includedCategories == [.agents, .daemons])
    #expect(inventory?.items.count == 1)
    // Malformed bytes in both groups: nothing is complete, so nothing is published.
    try Data("broken".utf8).write(to: agents.appendingPathComponent("broken.plist"))
    try Data("broken".utf8).write(to: daemons.appendingPathComponent("broken.plist"))
    let (blind, events) = await scanner.scan(metadata: history, enrich: false)
    #expect(blind == nil)
    #expect(events.count == 2)
}

@Test func persistenceUnparseableAndSymlinkedPlistsCannotHideAdditions() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let agents = root.appendingPathComponent("agents"), outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    func plist(_ label: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["Label": label, "Program": "/usr/bin/true"], format: .xml, options: 0)
    }
    try plist("fixture").write(to: agents.appendingPathComponent("fixture.plist"))
    let scanner = PersistenceScanner(files: [], directory: { $0 == .userAgents ? agents.path : root.appendingPathComponent("absent").path },
                                     overrides: { _ in .init(status: 0, output: "disabled services = {}", error: "") })
    #expect(await scanner.scan(metadata: history, enrich: false).1.isEmpty)
    // A malformed decoy and a real addition in the same scan: both are reported.
    let decoy = agents.appendingPathComponent("decoy.plist"), added = agents.appendingPathComponent("added.plist")
    try Data("broken".utf8).write(to: decoy)
    try plist("added").write(to: added)
    let (partial, blinded) = await scanner.scan(metadata: history, enrich: false)
    #expect(partial?.includedCategories.contains(.agents) == false)
    #expect(Set(blinded.map(\.subject)) == [decoy.path, added.path])
    try FileManager.default.removeItem(at: decoy)
    _ = await scanner.scan(metadata: history, enrich: false)
    // Symlinked plists parse through the link and retargeting to identical bytes is a change.
    let first = outside.appendingPathComponent("first.plist"), second = outside.appendingPathComponent("second.plist")
    try plist("linked").write(to: first)
    try plist("linked").write(to: second)
    let link = agents.appendingPathComponent("linked.plist")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: first.path)
    let (complete, linked) = await scanner.scan(metadata: history, enrich: false)
    #expect(complete?.includedCategories.contains(.agents) == true)
    #expect(complete?.items.contains { $0.path == link.path } == true)
    #expect(linked.map(\.subject) == [link.path] && linked.first?.details["change"] == "added")
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: second.path)
    let retargeted = await scanner.scan(metadata: history, enrich: false).1
    #expect(retargeted.map(\.subject) == [link.path] && retargeted.first?.details["change"] == "modified")
    #expect(await scanner.scan(metadata: history, enrich: false).1.isEmpty)
    // A self-referencing link terminates, is reported, and only marks the inventory incomplete.
    let loop = agents.appendingPathComponent("loop.plist")
    try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: loop.path)
    let (looped, loopEvents) = await scanner.scan(metadata: history, enrich: false)
    #expect(looped?.includedCategories.contains(.agents) == false)
    #expect(loopEvents.map(\.subject) == [loop.path])
}

@Test func persistenceLinksIntoAutomountRootsAreRefusedAndSymlinkedFilesTracked() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let agents = root.appendingPathComponent("agents"), dotfiles = root.appendingPathComponent("dotfiles")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
    let rcTarget = dotfiles.appendingPathComponent("zshrc"), rc = root.appendingPathComponent(".zshrc")
    try Data("first".utf8).write(to: rcTarget)
    try FileManager.default.createSymbolicLink(atPath: rc.path, withDestinationPath: "dotfiles/zshrc")
    let scanner = PersistenceScanner(files: [rc.path], directory: { $0 == .userAgents ? agents.path : root.appendingPathComponent("absent").path },
                                     overrides: { _ in .init(status: 0, output: "disabled services = {}", error: "") })
    #expect(BoundedFile.read(rc.path, followLinks: true) == Data("first".utf8))
    #expect(await scanner.scan(metadata: history, enrich: false).1.isEmpty)
    // A symlinked rc file changes through its target: reported as modified, not skipped.
    try Data("second".utf8).write(to: rcTarget)
    let modified = await scanner.scan(metadata: history, enrich: false).1
    #expect(modified.map(\.subject) == [rc.path] && modified.first?.details["change"] == "modified")
    // Automount targets are refused lexically: no mount attempt, still hashed by link text.
    let relative = String(repeating: "../", count: agents.path.split(separator: "/").count) + "net/192.0.2.1/x.plist"
    for target in ["/net/192.0.2.1/fixture.plist", "/home/fixture/fixture.plist", relative] {
        let link = agents.appendingPathComponent("remote.plist")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        #expect(BoundedFile.resolvedLinkTarget(link.path) == nil)
        let start = ContinuousClock.now
        let (inventory, events) = await scanner.scan(metadata: history, enrich: false)
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(inventory?.includedCategories.contains(.agents) == false)
        #expect(events.map(\.subject) == [link.path])
    }
    // A symlinked directory component is refused rather than resolved lexically.
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: dotfiles.path)
    let through = root.appendingPathComponent("through")
    try FileManager.default.createSymbolicLink(atPath: through.path, withDestinationPath: alias.path + "/zshrc")
    #expect(BoundedFile.resolvedLinkTarget(through.path) == nil)
}

@Test func enrichmentRefusesAutomountProgramsAndFlagsLocations() async {
    let start = ContinuousClock.now
    let refused = await CodeSigningVerdict.inspect("/home/fixture/.hidden/agent")
    #expect(start.duration(to: .now) < .milliseconds(500))
    #expect(refused.fields == ["signing": "unknown", "quarantine": "unknown", "location": "hidden-directory"])
    #expect(await CodeSigningVerdict.inspect("/net/192.0.2.1/agent").fields["signing"] == "unknown")
    #expect(CodeSigningVerdict.location("/private/var/folders/xy/T/agent") == "temporary-or-downloads")
    #expect(CodeSigningVerdict.location("/Users/fixture/Downloads/agent") == "temporary-or-downloads")
    #expect(CodeSigningVerdict.location("/Users/fixture/.cache/agent") == "hidden-directory")
    #expect(CodeSigningVerdict.location("/usr/local/bin/.agent") == "other")
}

@Test func persistenceConcurrentLinkAndAncestorSwapsStayBounded() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let agents = root.appendingPathComponent("agents"), alternate = root.appendingPathComponent("alternate")
    let outside = root.appendingPathComponent("outside")
    for directory in [agents, alternate, outside] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    let valid = try PropertyListSerialization.data(fromPropertyList: ["Label": "race", "Program": "/usr/bin/true"], format: .xml, options: 0)
    try valid.write(to: outside.appendingPathComponent("valid.plist"))
    try valid.write(to: agents.appendingPathComponent("stable.plist"))
    try FileManager.default.createSymbolicLink(atPath: alternate.appendingPathComponent("stable.plist").path, withDestinationPath: "/net/192.0.2.1/x.plist")
    let scanner = PersistenceScanner(files: [], directory: { $0 == .userAgents ? agents.path : root.appendingPathComponent("absent").path },
                                     overrides: { _ in .init(status: 0, output: "disabled services = {}", error: "") })
    _ = await scanner.scan(metadata: history, enrich: false)
    let targets = [outside.appendingPathComponent("valid.plist").path, "/net/192.0.2.1/x.plist", "/home/fixture/x.plist",
                   agents.appendingPathComponent("race.plist").path, outside.path, "../outside/valid.plist", "missing.plist"]
    let stop = Atomic<Bool>(false), swaps = Atomic<Int>(0)
    // Link retargeting and whole-directory exchanges race every scan stage.
    let racer = Thread {
        let link = agents.path + "/race.plist", staged = root.path + "/staged.plist"
        var index = 0
        while !stop.load(ordering: .relaxed) {
            unlink(staged)
            symlink(targets[index % targets.count], staged)
            rename(staged, link)
            if index % 16 == 0 { renamex_np(agents.path, alternate.path, UInt32(RENAME_SWAP)) }
            index += 1
            swaps.store(index, ordering: .relaxed)
        }
    }
    racer.start()
    var slowest = Duration.zero, inventories = 0, observed = 0
    for _ in 0..<60 {
        let start = ContinuousClock.now
        let (inventory, events) = await scanner.scan(metadata: history, enrich: false)
        slowest = max(slowest, start.duration(to: .now))
        if inventory != nil { inventories += 1 }
        observed += events.count
    }
    stop.store(true, ordering: .relaxed)
    while !racer.isFinished { try await Task.sleep(for: .milliseconds(5)) }
    // The race must actually have been observed, not merely survived.
    #expect(swaps.load(ordering: .relaxed) > 60 && inventories > 0 && observed > 0)
    #expect(slowest < .seconds(2))
    print("RACE swaps=\(swaps.load(ordering: .relaxed)) inventories=\(inventories) events=\(observed) slowest=\(slowest)")
}

#if !SMACK_APP_STORE
// Opt-in: needs a packaged app binary because the signature child is the app executable.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SMACK_ENRICHMENT_APP"] != nil, "Set SMACK_ENRICHMENT_APP to a packaged Smack binary"))
func persistenceLiveEnrichmentStormWithPackagedChild() async throws {
    let child = ProcessInfo.processInfo.environment["SMACK_ENRICHMENT_APP"]!
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let agents = root.appendingPathComponent("agents")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    let script = root.appendingPathComponent("unsigned-agent"), adHoc = root.appendingPathComponent("adhoc-agent")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
    chmod(script.path, 0o755)
    try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: adHoc.path)
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["--force", "--sign", "-", adHoc.path]
    try sign.run(); sign.waitUntilExit()
    #expect(sign.terminationStatus == 0)
    let programs = ["/bin/ls", child, script.path, adHoc.path]
    let scanner = PersistenceScanner(files: [], directory: { $0 == .userAgents ? agents.path : root.appendingPathComponent("absent").path },
                                     overrides: { _ in .init(status: 0, output: "disabled services = {}", error: "") },
                                     signatureChild: child)
    #expect(await scanner.scan(metadata: history).1.isEmpty)
    var programFor = [String: String]()
    func addPlists(_ prefix: String) throws {
        for index in 0..<40 {
            let path = agents.appendingPathComponent("\(prefix)-\(index).plist"), program = programs[index % programs.count]
            programFor[path.path] = program
            try PropertyListSerialization.data(fromPropertyList: ["Label": "\(prefix).\(index)", "Program": program], format: .xml, options: 0).write(to: path)
        }
    }
    try addPlists("storm")
    let start = ContinuousClock.now
    let events = await scanner.scan(metadata: history).1
    let elapsed = start.duration(to: .now)
    let enriched = events.filter { $0.details["signingIdentifier"] != nil || $0.details["quarantine"] != nil }
    #expect(events.count == 40)
    #expect(enriched.count == 20)
    func verdict(_ program: String) -> [String: String]? { enriched.first { programFor[$0.subject] == program }?.details }
    #expect(verdict("/bin/ls")?["signing"] == "signed" && verdict("/bin/ls")?["signingIdentifier"] == "com.apple.ls")
    #expect(verdict(script.path)?["signing"] == "unsigned")
    #expect(verdict(adHoc.path)?["signing"] == "ad-hoc")
    #expect(verdict(child)?["signing"] == "signed")
    print("ENRICHMENT storm events=\(events.count) enriched=\(enriched.count) wall=\(elapsed)")
    // Cancellation mid-enrichment loses nothing: the next scan still reports every addition.
    try addPlists("cancelled")
    let task = Task { await scanner.scan(metadata: history) }
    try await Task.sleep(for: .milliseconds(300))
    let cancelStart = ContinuousClock.now
    task.cancel()
    #expect(await task.value.1.isEmpty)
    let cancelElapsed = cancelStart.duration(to: .now)
    #expect(cancelElapsed < .seconds(4))
    let recovered = await scanner.scan(metadata: history).1
    #expect(recovered.count == 40 && recovered.allSatisfy { $0.subject.contains("/cancelled-") })
    print("ENRICHMENT cancel latency=\(cancelElapsed) recovered=\(recovered.count)")
}
#endif

@Test func profileFormattingDoesNotCreateFalseDiffs() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let scanner = PersistenceScanner(files: [])
    let prefix = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>"
    let a = "<key>A</key><array><string>one</string><string>two</string></array>"
    let b = "<key>B</key><data>AQID</data>"
    #expect(await scanner.profiles(prefix + a + b + "</dict></plist>", metadata: history)?.isEmpty == true)
    #expect(await scanner.profiles(prefix + b + "\n" + a + "</dict></plist>", metadata: history)?.isEmpty == true)
    #expect(await scanner.profiles(prefix + b + a.replacingOccurrences(of: "two", with: "three") + "</dict></plist>", metadata: history)?.count == 1)
}

@Test func persistenceSharesSignatureMetadataWithoutClaimingVerification() throws {
    let metadata = CodeSignatureInfo(trust: .signed, identifier: "fixture", teamIdentifier: "TEAM", certificateName: "Fixture CA",
                                     hardenedRuntime: true, entitlementsSummary: ["com.apple.security.app-sandbox"])
    let decoded = try JSONDecoder().decode(CodeSignatureInfo.self, from: JSONEncoder().encode(metadata))
    #expect(decoded == metadata)
    let fields = CodeSigningVerdict.fields(verificationSucceeded: true, metadata: decoded)
    #expect(fields["signing"] == "signed" && fields["teamIdentifier"] == "TEAM" && fields["certificate"] == "Fixture CA")
    #expect(fields["hardenedRuntime"] == "true" && fields["entitlements"] == "com.apple.security.app-sandbox")
    #expect(CodeSigningVerdict.fields(verificationSucceeded: false, metadata: metadata)["signing"] == "invalid-or-unverified")
    #expect(CodeSigningVerdict.fields(verificationSucceeded: true, metadata: .unavailable)["signing"] == "unknown")
}

#if !SMACK_APP_STORE
@MainActor @Test func watcherLiveFSEventsCreationDeletionRecreationAndStorm() async throws {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".smack-watcher-fixture-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent(".zshrc")
    // Keep SQLite writes outside the watched tree to avoid generating our own events.
    let dbRoot = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dbRoot) }
    let history = try HistoryRepository(databaseURL: dbRoot.appendingPathComponent("history.sqlite"))
    let scanner = PersistenceScanner(files: [file.path], directory: { _ in root.appendingPathComponent("absent").path },
                                     overrides: { _ in .init(status: 0, output: "disabled services = {}", error: "") })
    let state = Mutex((scans: 0, events: [ActivityEvent]()))
    let watcher = PersistenceWatcher(paths: [root.path], isRelevant: { $0.hasPrefix(root.path) }) { _ in
        let events = await scanner.scan(metadata: history, enrich: false).1
        state.withLock { $0.scans += 1; $0.events += events }
    }
    watcher.start(pollInterval: nil)
    defer { watcher.stop() }
    func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(condition())
    }
    try await waitFor { state.withLock { $0.scans >= 1 } }
    try Data("first".utf8).write(to: file)
    try await waitFor { state.withLock { $0.events.contains { $0.subject == file.path && $0.details["change"] == "added" } } }
    try FileManager.default.removeItem(at: file)
    try await waitFor { state.withLock { $0.events.contains { $0.subject == file.path && $0.details["change"] == "removed" } } }
    for index in 0..<500 { try Data("storm-\(index)".utf8).write(to: file, options: .atomic) }
    try await waitFor { state.withLock { $0.events.filter { $0.subject == file.path && $0.details["change"] == "added" }.count >= 2 } }
    #expect(state.withLock { $0.scans } < 20)
}

@MainActor @Test func watcherLiveFSEventsWatchedRootDeletionAndRecreation() async throws {
    let parent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".smack-watcher-root-" + UUID().uuidString)
    let root = parent.appendingPathComponent("watched")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let file = root.appendingPathComponent(".zshrc")
    try Data("first".utf8).write(to: file)
    let dbRoot = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dbRoot) }
    let history = try HistoryRepository(databaseURL: dbRoot.appendingPathComponent("history.sqlite"))
    let scanner = PersistenceScanner(files: [file.path], directory: { _ in dbRoot.appendingPathComponent("absent").path },
                                     overrides: { _ in .init(status: 0, output: "disabled services = {}", error: "") })
    let state = Mutex((scans: 0, events: [ActivityEvent]()))
    // Relevance rejects every path: only the RootChanged flag can trigger these rescans.
    let watcher = PersistenceWatcher(paths: [root.path], isRelevant: { _ in false }) { _ in
        let events = await scanner.scan(metadata: history, enrich: false).1
        state.withLock { $0.scans += 1; $0.events += events }
    }
    watcher.start(pollInterval: nil)
    defer { watcher.stop() }
    func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(condition())
    }
    try await waitFor { state.withLock { $0.scans >= 1 } }
    try FileManager.default.removeItem(at: root)
    try await waitFor { state.withLock { $0.events.contains { $0.subject == file.path && $0.details["change"] == "removed" } } }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try Data("second".utf8).write(to: file)
    try await waitFor { state.withLock { $0.events.contains { $0.subject == file.path && $0.details["change"] == "added" } } }
}
#endif

@Test func persistenceFixtureBaselinePartialCategoriesChangesAndCancellation() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let agents = root.appendingPathComponent("agents")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    let path = agents.appendingPathComponent("fixture.plist")
    let shell = root.appendingPathComponent(".zshrc")
    try Data("first".utf8).write(to: shell)
    let plist: [String: Any] = ["Label": "test.fixture", "Program": "/usr/bin/true", "RunAtLoad": true]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: path)
    let scanner = PersistenceScanner(files: [shell.path], directory: { location in
        location == .userAgents ? agents.path : root.appendingPathComponent("absent").path
    }, overrides: { _ in .init(status: 0, output: "disabled services = {}", error: "") })
    let (first, baseline) = await scanner.scan(metadata: history)
    #expect(baseline.isEmpty)
    #expect(first?.includedCategories == [.agents, .daemons])
    #expect(first?.items.count == 1)
    try Data("second".utf8).write(to: shell)
    let (_, changes) = await scanner.scan(metadata: history)
    #expect(changes.contains { $0.subject == shell.path && $0.kind == .persistenceFileChanged && $0.severity == .info })
    let reopened = PersistenceScanner(files: [shell.path], directory: { location in
        location == .userAgents ? agents.path : root.appendingPathComponent("absent").path
    }, overrides: { _ in .init(status: 0, output: "disabled services = {}", error: "") })
    #expect(await reopened.scan(metadata: history).1.isEmpty)
    // Malformed input makes the category incomplete; it cannot remove previously observed agents.
    try Data("broken".utf8).write(to: path)
    let (partial, _) = await scanner.scan(metadata: history)
    #expect(partial?.includedCategories.contains(.agents) == false)
    let task = Task { await scanner.scan(metadata: history) }
    task.cancel()
    #expect(await task.value.1.isEmpty)
}

@Test func profileDiffBaselineSurvivesRestartAndRejectsMalformedPayload() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let first = PersistenceScanner(files: [], directory: { _ in root.appendingPathComponent("absent").path })
    func xml(_ value: String) throws -> String {
        String(decoding: try PropertyListSerialization.data(fromPropertyList: ["profile": value], format: .xml, options: 0), as: UTF8.self)
    }
    #expect(await first.profiles("broken", metadata: history) == nil)
    #expect(try await first.profiles(xml("baseline"), metadata: history)?.isEmpty == true)
    let restarted = PersistenceScanner(files: [], directory: { _ in root.appendingPathComponent("absent").path })
    #expect(try await restarted.profiles(xml("baseline"), metadata: history)?.isEmpty == true)
    let events = try await restarted.profiles(xml("changed"), metadata: history)
    #expect(events?.count == 1 && events?.first?.details["regression"] == "false")
}

@MainActor @Test func watcherDebouncesAndStopCancelsPendingWork() async throws {
    let count = Mutex(0)
    let watcher = PersistenceWatcher { _ in count.withLock { $0 += 1 } }
    for _ in 0..<200 { watcher.receive(paths: ["/Library/LaunchDaemons/fixture.plist"]) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while count.withLock({ $0 }) == 0 && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(count.withLock { $0 } == 1)
    watcher.receive(paths: [], mustRescan: true)
    watcher.stop()
    try await Task.sleep(for: .milliseconds(2200))
    #expect(count.withLock { $0 } == 1)
}

@MainActor @Test func watcherContinuousInputCannotStarveRescans() async throws {
    let count = Mutex(0)
    let watcher = PersistenceWatcher { _ in count.withLock { $0 += 1 } }
    defer { watcher.stop() }
    for _ in 0..<35 {
        watcher.receive(paths: [], mustRescan: true)
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(count.withLock { $0 } >= 1)
}

@Test func profileFirstDoesNotSeedFileBaseline() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent(".zshrc")
    try Data("baseline".utf8).write(to: file)
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let scanner = PersistenceScanner(files: [file.path], directory: { _ in root.appendingPathComponent("absent").path },
                                     overrides: { _ in .init(status: 0, output: "disabled services = {}", error: "") })
    #expect(await scanner.profiles("{profile = baseline;}", metadata: history)?.isEmpty == true)
    #expect(await scanner.scan(metadata: history, enrich: false).1.isEmpty)
    try Data("changed".utf8).write(to: file)
    #expect(await scanner.scan(metadata: history, enrich: false).1.contains { $0.subject == file.path })
}
