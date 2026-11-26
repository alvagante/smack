import Foundation
import SQLite3

enum PostureStatus: String, Codable, Sendable { case pass, warn, fail, unknown }
enum PostureArea: String, Codable, Sendable { case system, network, privacy }

struct PostureCheck: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var area: PostureArea = .system
    var status: PostureStatus
    var summary: String
    var evidence: String
    var reason: String?
    var remediation: String? = "Review this check in System Settings > Privacy & Security. Smack never changes security settings."
    var settingsURL: URL? = URL(string: "x-apple.systempreferences:com.apple.preference.security")

    init(id: String, area: PostureArea = .system, status: PostureStatus, summary: String,
         evidence: String, reason: String? = nil,
         remediation: String? = "Review this check in System Settings > Privacy & Security. Smack never changes security settings.") {
        self.id = id; self.area = area; self.status = status
        self.summary = Self.capped(summary, bytes: 1024)
        self.evidence = Self.capped(evidence, bytes: 4096)
        self.reason = status == .unknown ? (reason ?? "Observation unavailable") : reason
        self.remediation = remediation
    }

    static func capped(_ text: String, bytes limit: Int) -> String {
        var bytes = Array(text.utf8.prefix(limit))
        while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func unknown(_ id: String, _ reason: String) -> Self {
        .init(id: id, status: .unknown, summary: "Unavailable", evidence: "", reason: reason)
    }
}

struct PostureSnapshot: Codable, Sendable, Equatable {
    var timestamp: Date
    var checks: [PostureCheck]
    static let metadataKey = "posture.snapshot.v1"

    func changes(from previous: Self?) -> [ActivityEvent] {
        guard let previous else { return [] }
        return checks.compactMap { check in
            guard let old = previous.checks.first(where: { $0.id == check.id }), old.status != check.status else { return nil }
            let regression = (old.status == .pass && [.warn, .fail].contains(check.status))
                || (old.status == .warn && check.status == .fail)
            return .make(kind: .postureChanged, timestamp: timestamp, subject: check.id,
                severity: regression ? .warning : .info,
                details: ["check": check.id, "old": old.status.rawValue, "new": check.status.rawValue,
                          "regression": String(regression), "summary": check.summary])
        }
    }
}

enum PostureParser {
    static let ids = ["sip", "authenticated-root", "filevault", "gatekeeper", "firewall", "firewall-stealth",
        "auto-update", "xprotect", "mdm", "config-profiles", "system-extensions", "remote-login",
        "screen-sharing", "file-sharing", "auto-login", "guest", "lockdown", "tcc-user", "tcc-system"]

    static func command(_ id: String, _ result: CommandRunner.Result) -> PostureCheck {
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        var check = PostureCheck.unknown(id, "Unrecognized tool output")
        check.evidence = PostureCheck.capped(text + "\n" + result.error, bytes: 4096)
        guard result.status == 0, !result.timedOut, !result.cancelled, !result.truncated else {
            check.reason = result.timedOut ? "Check timed out" : "Tool failed, cancelled or output exceeded limit"
            return check
        }
        let lower = text.lowercased()
        let status: PostureStatus?
        switch id {
        case "sip", "authenticated-root":
            status = lower.contains("custom configuration") ? .warn : lower.contains("disabled") ? .fail : lower.contains("enabled") ? .pass : nil
        case "filevault":
            status = lower.contains("encryption in progress") || lower.contains("encrypting") ? .warn : lower.contains("filevault is on") ? .pass : lower.contains("filevault is off") ? .fail : nil
        case "gatekeeper": status = lower == "assessments enabled" ? .pass : lower == "assessments disabled" ? .fail : nil
        case "firewall": status = lower.contains("state = 1") ? .pass : lower.contains("state = 0") ? .fail : nil
        case "firewall-stealth": status = lower.contains("enabled") ? .pass : lower.contains("disabled") ? .warn : nil
        case "mdm": status = lower.contains("mdm enrollment:") && lower.contains("enrolled via dep:") ? .pass : nil
        case "system-extensions": status = lower.contains("extension(s)") ? .pass : nil
        default: status = nil
        }
        if let status { check.status = status; check.summary = String(text.prefix(512)); check.reason = nil }
        return check
    }

    static func preferences(_ id: String, _ plist: [String: Any]?) -> PostureCheck {
        guard let plist else { return .unknown(id, "Preference file unreadable or absent; effective defaults are unknown") }
        var status: PostureStatus = .unknown
        var evidence = ""
        switch id {
        case "auto-update":
            let keys = ["AutomaticCheckEnabled", "CriticalUpdateInstall", "AutomaticallyInstallMacOSUpdates"]
            evidence = keys.map { "\($0)=\(plist[$0].map(String.init(describing:)) ?? "absent")" }.joined(separator: ", ")
            if let checks = plist[keys[0]] as? Bool {
                status = !checks ? .fail : keys.allSatisfy { plist[$0] as? Bool == true } ? .pass : .warn
            }
        case "auto-login": status = plist["autoLoginUser"] as? String == nil ? .pass : .fail; evidence = "autoLoginUser present: \(plist["autoLoginUser"] != nil)"
        case "guest": if let value = plist["GuestEnabled"] as? Bool { status = value ? .warn : .pass; evidence = "GuestEnabled=\(value)" }
        case "lockdown": if let value = plist["LDMGlobalEnabled"] as? Bool { status = .pass; evidence = "LDMGlobalEnabled=\(value) (informational)" }
        default: break
        }
        return .init(id: id, status: status, summary: evidence.isEmpty ? "Unavailable" : evidence,
                     evidence: evidence, reason: status == .unknown ? "Effective preference not explicitly set" : nil)
    }

    static func tcc(_ id: String, path: String) -> PostureCheck {
        var db: OpaquePointer?
        defer { if let db { sqlite3_close(db) } }
        // Immutable read-only access never creates a database or its journal.
        var components = URLComponents(url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        guard sqlite3_open_v2(components.string!, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            return .unknown(id, "Full Disk Access not granted to Smack, or TCC database unavailable")
        }
        sqlite3_busy_timeout(db, 50)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT service, client, auth_value, last_modified FROM access LIMIT 1001", -1, &statement, nil) == SQLITE_OK else {
            return .unknown(id, "Unsupported TCC schema or access denied")
        }
        let services = Set(["Accessibility", "ScreenCapture", "SystemPolicyAllFiles", "ListenEvent", "PostEvent", "Microphone", "Camera", "AppleEvents", "DeveloperTool"].map { "kTCCService" + $0 })
        var rows = [String](), count = 0
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            count += 1
            if count > 1000 { return .unknown(id, "TCC row limit exceeded") }
            if let service = sqlite3_column_text(statement, 0), let client = sqlite3_column_text(statement, 1) {
                let name = String(cString: service)
                if services.contains(name) { rows.append("\(name): \(String(cString: client).prefix(256)) auth=\(sqlite3_column_int(statement, 2)) modified=\(sqlite3_column_int64(statement, 3))") }
            }
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { return .unknown(id, "TCC read failed") }
        return .init(id: id, area: .privacy, status: .pass, summary: "\(rows.count) TCC entries (informational)",
                     evidence: String(rows.joined(separator: "\n").prefix(4096)))
    }

    static func xprotect(_ versions: [(String, Date)], expectedCount: Int, now: Date) -> PostureCheck {
        guard !versions.isEmpty, versions.count == expectedCount,
              versions.allSatisfy({ !$0.0.isEmpty && now.timeIntervalSince($0.1).isFinite && $0.1 <= now }) else {
            return .unknown("xprotect", "XProtect version or modification date unavailable or invalid")
        }
        let age = versions.map { now.timeIntervalSince($0.1) }.max()!
        return .init(id: "xprotect", status: age < 30 * 86400 ? .pass : age < 90 * 86400 ? .warn : .fail,
                     summary: "Installed XProtect versions", evidence: versions.map { "\($0.0) modified \($0.1.ISO8601Format())" }.joined(separator: "\n"))
    }
}

struct PostureCollector: Sendable {
    typealias Run = @Sendable (String, [String], TimeInterval) async -> CommandRunner.Result
    var run: Run = { await CommandRunner.run($0, $1, timeout: $2, outputLimit: 4096) }

    func collect(listeners: NetworkPortSnapshot?, profile: PostureCheck? = nil, now: Date = Date()) async -> PostureSnapshot {
        guard Capabilities.supportsPostureChecks else {
            return .init(timestamp: now, checks: PostureParser.ids.map { .unknown($0, "Not available in this edition") })
        }
        let commands: [(String, String, [String])] = [
            ("sip", "/usr/bin/csrutil", ["status"]), ("authenticated-root", "/usr/bin/csrutil", ["authenticated-root", "status"]),
            ("filevault", "/usr/bin/fdesetup", ["status"]), ("gatekeeper", "/usr/sbin/spctl", ["--status"]),
            ("firewall", "/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]),
            ("firewall-stealth", "/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getstealthmode"]),
            ("mdm", "/usr/bin/profiles", ["status", "-type", "enrollment"]),
            ("system-extensions", "/usr/bin/systemextensionsctl", ["list"])]
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        var checks = [PostureCheck]()
        // Serial probes bound concurrency to one, including subprocess teardown.
        for (id, executable, arguments) in commands {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if Task.isCancelled || remaining <= 0 { checks.append(.unknown(id, "Collection cancelled or deadline exceeded")); continue }
            checks.append(PostureParser.command(id, await run(executable, arguments, min(5, remaining))))
        }
        func plist(_ path: String) -> [String: Any]? {
            guard let data = BoundedFile.read(path) else { return nil }
            return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for (id, path) in [("auto-update", "/Library/Preferences/com.apple.SoftwareUpdate.plist"),
                           ("auto-login", "/Library/Preferences/com.apple.loginwindow.plist"),
                           ("guest", "/Library/Preferences/com.apple.loginwindow.plist"),
                           ("lockdown", home + "/Library/Preferences/.GlobalPreferences.plist")] {
            checks.append(PostureParser.preferences(id, plist(path)))
        }
        let paths = ["/Library/Apple/System/Library/CoreServices/XProtect.bundle", "/Library/Apple/System/Library/CoreServices/XProtect.app"]
        let versions = paths.compactMap { path -> (String, Date)? in
            guard let version = plist(path + "/Contents/Info.plist")?["CFBundleShortVersionString"] as? String,
                  let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date else { return nil }
            return (version, date)
        }
        checks.append(PostureParser.xprotect(versions, expectedCount: paths.count, now: now))
        checks.append(profile ?? .unknown("config-profiles", "Requires helper protocol v2; missing helper: enable it, older helper: Update Helper"))
        for (id, ports) in [("remote-login", [22]), ("screen-sharing", [5900, 3283]), ("file-sharing", [445, 548])] {
            guard let listeners else { checks.append(.unknown(id, "No cached listener snapshot")); continue }
            let open = listeners.ports.contains { ports.contains(Int($0.port)) && $0.scope == .external }
            checks.append(.init(id: id, area: .network, status: open ? .warn : .unknown,
                summary: open ? "External listener observed" : "No external listener observed",
                evidence: "Cached listeners at \(listeners.timestamp.ISO8601Format()); root-owned listeners may be missing",
                reason: open ? nil : "Incomplete listener coverage cannot prove this service is disabled"))
        }
        for (id, path) in [("tcc-user", home + "/Library/Application Support/com.apple.TCC/TCC.db"),
                           ("tcc-system", "/Library/Application Support/com.apple.TCC/TCC.db")] {
            checks.append(Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline
                ? .unknown(id, "Collection cancelled or deadline exceeded") : PostureParser.tcc(id, path: path))
        }
        return .init(timestamp: now, checks: checks)
    }
}
