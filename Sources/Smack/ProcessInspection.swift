import Darwin
import Foundation
import Security

enum ProcessInspectionTab: String, CaseIterable, Identifiable {
    case launchContext = "Launch Context"
    case logs = "Logs"
    case startup = "Startup"
    case security = "Security"
    case fileActivity = "File Activity"
    var id: Self { self }
}

struct InspectionField: Identifiable, Sendable {
    var id: String { label }
    var label: String
    var value: String
}

struct LaunchContext: Sendable {
    var arguments: [String]
    var environment: [InspectionField]
}

/// Inspections are separate from the sampling loop and never persist environment values.
enum ProcessInspection {
    static func isCurrent(_ identity: ProcessIdentity) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(identity.pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000) == identity.startTime
    }

    static func launchContext(pid: Int32) -> LaunchContext? {
#if SMACK_APP_STORE
        return nil
#else
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var count = 1_048_576
        var buffer = [UInt8](repeating: 0, count: count)
        let status = buffer.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &count, nil, 0) }
        guard status == 0 else { return nil }
        return parseArguments(Data(buffer.prefix(count)))
#endif
    }

    static func parseArguments(_ data: Data) -> LaunchContext? {
        let bytes = Array(data)
        guard bytes.count >= 4 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 65_536 else { return nil }
        var offset = 4
        func string() -> String? {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            defer { offset = end + 1 }
            return String(decoding: bytes[offset..<end], as: UTF8.self)
        }
        guard string() != nil else { return nil } // Executable path precedes argv.
        while offset < bytes.count, bytes[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<argc {
            guard let value = string() else { return nil }
            arguments.append(value)
        }
        var environment: [InspectionField] = []
        while let value = string(), !value.isEmpty {
            guard let equals = value.firstIndex(of: "=") else { continue }
            let name = String(value[..<equals])
            let raw = String(value[value.index(after: equals)...])
            // Values are hidden by default, including credentials under unexpected names.
            environment.append(InspectionField(label: name, value: raw.isEmpty ? "(empty)" : "••••"))
        }
        return LaunchContext(arguments: redactArguments(arguments), environment: environment.sorted { $0.label < $1.label })
    }

    static func redactArguments(_ arguments: [String]) -> [String] {
        let sensitive = ["password", "passwd", "token", "secret", "credential", "api-key", "api_key", "authorization", "cookie"]
        var hideNext = false
        return arguments.map { argument in
            if hideNext { hideNext = false; return "••••" }
            let key = argument.components(separatedBy: "=")[0].lowercased()
            if sensitive.contains(where: key.contains) {
                if let equals = argument.firstIndex(of: "=") { return String(argument[...equals]) + "••••" }
                hideNext = true
            }
            return argument
        }
    }

    static func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static func security(pid: Int32, path: String?) -> [InspectionField] {
        var fields: [InspectionField] = []
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            fields += [
                InspectionField(label: "Effective UID / GID", value: "\(info.pbi_uid) / \(info.pbi_gid)"),
                InspectionField(label: "Real UID / GID", value: "\(info.pbi_ruid) / \(info.pbi_rgid)")
            ]
        }
        guard let path else { return fields }
        let signature = ProcessProvenanceResolver.signature(path: path)
        fields += [
            InspectionField(label: "Executable signature", value: signature.trustDescription),
            InspectionField(label: "Signing identifier", value: signature.identifier ?? "Unavailable"),
            InspectionField(label: "Team", value: signature.teamIdentifier ?? "Unavailable"),
            InspectionField(label: "Certificate", value: signature.certificateName ?? "Unavailable"),
            InspectionField(label: "Hardened runtime", value: signature.trust == .unavailable ? "Unavailable" : signature.hardenedRuntime ? "Yes" : "No")
        ]
        var code: SecStaticCode?
        var information: CFDictionary?
        if SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
           let code,
           SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
           let dict = information as? [String: Any] {
            let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
            fields.append(InspectionField(label: "Sandbox entitlement", value: (entitlements["com.apple.security.app-sandbox"] as? Bool) == true ? "Yes" : "No"))
            for key in entitlements.keys.sorted() {
                fields.append(InspectionField(label: key, value: String(describing: entitlements[key]!)))
            }
        }
        return fields
    }

    static func logArguments(identity: ProcessIdentity, since: Date, severity: String) -> [String] {
        let start = max(since, identity.startTime)
        var predicate = "processID == \(identity.pid)"
        if severity == "Errors" { predicate += " AND (messageType == error OR messageType == fault)" }
        return ["show", "--style", "ndjson", "--start", "@\(Int64(ceil(start.timeIntervalSince1970)))", "--predicate", predicate, "--info", "--debug"]
    }

    static func logLines(_ output: String, filter: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = object["eventMessage"] as? String else { return nil }
            let text = "\(object["timestamp"] ?? "") [\(object["messageType"] ?? "Default")] \(message)"
            return filter.isEmpty || text.localizedCaseInsensitiveContains(filter) ? text : nil
        }
    }

    static func matches(_ item: StartupItem, process: ProcessMetrics) -> Bool {
        if item.pid == process.identity.pid { return true }
        guard let path = process.executablePath else { return false }
        if item.program == path { return true }
        if let itemPath = item.path, itemPath.hasSuffix(".app") {
            return path.hasPrefix(itemPath + "/")
        }
        return false
    }
}

