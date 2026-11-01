import Foundation
import Darwin
import SmackIPC

func main() -> Int32 {
    let baselineInvocation = CommandLine.arguments.dropFirst().first == "baseline"
    var args = Array(CommandLine.arguments.dropFirst())
    let launch = args.contains("--launch")
    args.removeAll { $0 == "--launch" }
    let json = args.contains("--json")
    args.removeAll { $0 == "--json" }
    var explicitFormat: CLIOutputFormat?
    if let index = args.firstIndex(of: "--format") {
        guard index + 1 < args.count, let format = CLIOutputFormat(rawValue: args[index + 1]) else { return baselineInvocation ? 1 : 2 }
        explicitFormat = format
        args.removeSubrange(index...index + 1)
    }
    guard !json || explicitFormat == nil || explicitFormat == .json else { return baselineInvocation ? 1 : 2 }
    let format = explicitFormat ?? (json || isatty(STDOUT_FILENO) == 0 ? .json : .table)
    var paths = ControlSocket.paths()
    if let index = args.firstIndex(of: "--socket"), index + 1 < args.count {
        paths = [args[index + 1]]; args.removeSubrange(index...index + 1)
    }
    guard let op = args.first, ["baseline", "status", "ps", "apps", "ports", "devservers", "agents", "who", "events", "history", "startup", "posture", "alerts", "open"].contains(op) else {
        fputs("Usage: smack <baseline|status|ps|apps|ports|devservers|agents|who|events|history|startup|posture|alerts|open> [--json | --format table|json|csv|tsv] [--socket path] [--limit N] [--port N]\n", stderr)
        return baselineInvocation ? 1 : 2
    }
    args.removeFirst()
    var request = ControlRequest(op: op)
    var outputPath: String?
    if op == "baseline" {
        guard let action = args.first, ["create", "list", "diff", "export"].contains(action) else { return 1 }
        request.action = args.removeFirst()
        if ["diff", "export"].contains(action), let base = args.first, !base.hasPrefix("-") {
            request.base = args.removeFirst()
        }
    }
    if op == "who" {
        guard let value = args.first, let port = Int(value), (1...65535).contains(port) else { return baselineInvocation ? 1 : 2 }
        request.port = port
        args.removeFirst()
    }
    if op == "open", !args.isEmpty { request.url = args.removeFirst() }
    if op == "alerts", let action = args.first, ["pause", "resume", "snooze"].contains(action) {
        request.action = args.removeFirst()
        if action == "snooze" {
            guard args.count >= 2 else { return baselineInvocation ? 1 : 2 }
            request.ruleID = args.removeFirst()
            request.duration = duration(args.removeFirst())
            guard request.duration != nil else { return baselineInvocation ? 1 : 2 }
        } else if action == "pause", let value = args.first, !value.hasPrefix("--") {
            request.duration = duration(args.removeFirst())
            guard request.duration != nil else { return baselineInvocation ? 1 : 2 }
        }
    }
    while !args.isEmpty {
        let flag = args.removeFirst()
        if flag == "--strict" { request.strict = true; continue }
        if flag == "--follow" { request.follow = true; continue }
        guard !args.isEmpty else { return baselineInvocation ? 1 : 2 }
        let value = args.removeFirst()
        switch flag {
        case "--name": request.name = value
        case "--sections": request.sections = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        case "--against": request.against = value
        case "-o", "--output": guard op == "baseline", request.action == "export" else { return 1 }; outputPath = value
        case "--limit": guard let n = Int(value) else { return baselineInvocation ? 1 : 2 }; request.limit = n
        case "--port": guard let n = Int(value) else { return baselineInvocation ? 1 : 2 }; request.port = n
        case "--sort": guard ["cpu", "memory"].contains(value) else { return baselineInvocation ? 1 : 2 }; request.sort = value
        case "--app": request.app = value
        case "--since", "--until":
            let date: Date
            if let absolute = try? Date(value, strategy: .iso8601) { date = absolute }
            else if flag == "--since", let seconds = duration(value), (1...2678400).contains(seconds) {
                date = Date().addingTimeInterval(-seconds)
            } else { return baselineInvocation ? 1 : 2 }
            if flag == "--since" { request.since = date.timeIntervalSince1970 }
            else { request.until = date.timeIntervalSince1970 }
        case "--kinds": request.kinds = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        case "--search": request.search = value
        case "--metric": request.metric = value
        case "--resolution": guard let seconds = duration(value) else { return baselineInvocation ? 1 : 2 }; request.resolution = seconds
        default: return baselineInvocation ? 1 : 2
        }
    }
    if op == "baseline" {
        guard explicitFormat == nil || explicitFormat == .json || explicitFormat == .table else { return 1 }
        if request.action == "diff", let base = request.base,
           base.contains("/") || FileManager.default.fileExists(atPath: base) {
            request.base = URL(fileURLWithPath: base).standardizedFileURL.path
        }
        if let against = request.against, against != "now" {
            request.against = URL(fileURLWithPath: against).standardizedFileURL.path
        }
    }
    do { try request.validate() } catch { return baselineInvocation ? 1 : 2 }
    var connection: Int32?
    for path in paths {
        if let fd = try? ControlSocket.connect(path) { connection = fd; break }
    }
    func connect() -> Int32? {
        for path in paths { if let fd = try? ControlSocket.connect(path) { return fd } }
        return nil
    }
    // Set only when this invocation started Smack: a fresh app answers unavailable until its first
    // sample or scan, so those answers are retried until the same deadline.
    var launchDeadline: TimeInterval?
    if connection == nil && launch {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-b", "it.lab42.smack"]
        do { try process.run(); process.waitUntilExit() } catch { return baselineInvocation ? 1 : 3 }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        launchDeadline = deadline
        while connection == nil && ProcessInfo.processInfo.systemUptime < deadline {
            connection = connect()
            if connection == nil { Thread.sleep(forTimeInterval: 0.1) }
        }
    }
    guard var fd = connection else { fputs("Smack is not running\n", stderr); return op == "baseline" ? 1 : 3 }
    if op == "baseline" {
        var timeout = timeval(tv_sec: 65, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }
    defer { close(fd) }
    do {
        try ControlSocket.write(try JSONEncoder().encode(request) + Data([10]), to: fd)
        var reader = ControlResponseReader()
        var printedHeader = false
        repeat {
            let response = try reader.next(from: fd)
            guard response.version == ControlProtocol.version else { return baselineInvocation ? 1 : 4 }
            if response.error == .unavailable, !baselineInvocation, !printedHeader, let deadline = launchDeadline,
               ProcessInfo.processInfo.systemUptime + 0.5 < deadline {
                Thread.sleep(forTimeInterval: 0.5)
                close(fd)
                guard let next = connect() else { fputs("Smack is not running\n", stderr); fd = -1; return baselineInvocation ? 1 : 3 }
                fd = next
                reader = ControlResponseReader()
                try ControlSocket.write(try JSONEncoder().encode(request) + Data([10]), to: fd)
                continue
            }
            if let error = response.error {
                if let message = response.metadata?["message"] { fputs(try CLIOutputFormat.escaped(message) + "\n", stderr) }
                fputs("\(error.rawValue) (app protocol \(response.version), CLI protocol \(request.version))\n", stderr)
                return error == .unsupportedVersion && !baselineInvocation ? 4 : 1
            }
            if op == "baseline" {
                if let path = response.metadata?["path"] { print(try CLIOutputFormat.escaped(path)) }
                if let payload = response.metadata?["payload"] {
                    let text = request.action == "diff" && format == .table ? response.metadata?["markdown"] ?? payload : payload
                    if let outputPath { try Data(text.utf8).write(to: URL(fileURLWithPath: outputPath), options: .atomic) }
                    else if format == .table { print(try CLIOutputFormat.terminalMarkdown(text)) }
                    else { print(text) }
                }
                if request.action == "list" {
                    if json { print(String(decoding: try JSONEncoder().encode(response.records), as: UTF8.self)) }
                    else { for row in response.records { print(try CLIOutputFormat.escaped(row.id) + "\t" + CLIOutputFormat.escaped(row.title)) } }
                }
                return response.metadata?["drift"] == "true" ? 2 : 0
            }
            if !printedHeader {
                printedHeader = true
                if let header = format.header(op: op) { print(header, terminator: format.lineEnding) }
            }
            for record in response.records {
                print(try format.row(record, op: op), terminator: format.lineEnding)
            }
            if response.end { break }
            fflush(stdout)
        } while true
        return 0
    } catch {
        let message = (try? CLIOutputFormat.escaped(String(describing: error))) ?? "Unknown error"
        fputs("Control request failed: \(message)\n", stderr)
        return 1
    }
}
func duration(_ value: String) -> Double? {
    if let seconds = Double(value), seconds.isFinite { return seconds }
    guard let suffix = value.last, let number = Double(value.dropLast()),
          let scale = ["s": 1.0, "m": 60.0, "h": 3600.0, "d": 86400.0][String(suffix)] else { return nil }
    return number * scale
}
exit(main())
