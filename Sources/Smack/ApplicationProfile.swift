import Foundation

// MARK: - Tools

/// Command-line tools that profile one process. Every run is an explicit user action.
enum ProfileTool: String, CaseIterable, Identifiable, Sendable {
    case footprint
    case vmmap
    case heap
    case leaks
    case sample

    var id: Self { self }

    var title: String {
        switch self {
        case .footprint: "Footprint"
        case .vmmap: "Virtual Memory"
        case .heap: "Heap"
        case .leaks: "Leaks"
        case .sample: "CPU Sample"
        }
    }

    var executable: String { "/usr/bin/\(rawValue)" }

    var summary: String {
        switch self {
        case .footprint: "Dirty, clean and reclaimable memory by category."
        case .vmmap: "Virtual memory regions: where resident, dirty and swapped memory lives."
        case .heap: "Live malloc allocations grouped by class."
        case .leaks: "Unreachable allocations."
        case .sample: "Where the process spends CPU time, over 3 seconds."
        }
    }

    /// `leaks` and `heap` walk the target's memory and suspend it while they do.
    var pausesProcess: Bool { self == .leaks || self == .heap }

    var timeout: TimeInterval {
        switch self {
        case .footprint, .vmmap: 30
        case .heap, .leaks: 120
        case .sample: 30
        }
    }

    func arguments(pid: Int32) -> [String] {
        switch self {
        case .footprint: ["-p", "\(pid)"]
        case .vmmap: ["-summary", "\(pid)"]
        case .heap, .leaks: ["\(pid)"]
        case .sample: ["\(pid)", "3", "-file", "/dev/stdout"]
        }
    }

    func commandLine(pid: Int32) -> String {
        ([executable] + arguments(pid: pid)).joined(separator: " ")
    }

    /// `leaks` exits 1 when it finds leaks, which is a result and not a failure.
    func succeeded(status: Int32) -> Bool {
        self == .leaks ? status == 0 || status == 1 : status == 0
    }
}

// MARK: - Report

enum ProfileSeverity: Sendable {
    case normal
    case notable
    case alert
}

struct ProfileHighlight: Identifiable, Sendable, Equatable {
    let id = UUID()
    var label: String
    var value: String
    var severity = ProfileSeverity.normal

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.label == rhs.label && lhs.value == rhs.value && lhs.severity == rhs.severity
    }
}

struct ProfileReport: Identifiable, Sendable {
    let id = UUID()
    var tool: ProfileTool
    var pid: Int32
    var output: String
    var failure: String?
    var duration: TimeInterval
    var highlights: [ProfileHighlight]
    var truncated = false
}

// MARK: - Parsing

/// Pulls the few lines that matter out of each tool's output; the full text stays available next to them.
enum ProfileParser {
    static let highlightRows = 5

    static func highlights(for tool: ProfileTool, output: String) -> [ProfileHighlight] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        switch tool {
        case .footprint: return footprint(lines)
        case .vmmap: return vmmap(lines)
        case .heap: return heap(lines)
        case .leaks: return leaks(lines)
        case .sample: return sample(lines)
        }
    }

    /// "336 KB", "64.0M", "56" (plain bytes) or "1.5GB".
    static func bytes(_ token: String) -> UInt64? {
        var text = token.replacingOccurrences(of: " ", with: "")
        if text.hasSuffix("B") { text.removeLast() }
        var scale = 1.0
        if let last = text.last, let unit = "KMGT".firstIndex(of: last) {
            scale = pow(1024, Double("KMGT".distance(from: "KMGT".startIndex, to: unit) + 1))
            text.removeLast()
        }
        guard let value = Double(text), value >= 0 else { return nil }
        return UInt64(value * scale)
    }

    private static func value(after prefix: String, in lines: [String]) -> String? {
        lines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
    }

    private static func size(_ value: UInt64) -> String { Formatting.bytes(value) }

    // MARK: footprint

    private static func footprint(_ lines: [String]) -> [ProfileHighlight] {
        var result: [ProfileHighlight] = []
        if let line = lines.first(where: { $0.contains("Footprint:") }),
           let range = line.range(of: "Footprint:") {
            let total = line[range.upperBound...].components(separatedBy: " (").first?.trimmingCharacters(in: .whitespaces) ?? ""
            result.append(ProfileHighlight(label: "Footprint", value: total))
        }
        if let peak = value(after: "phys_footprint_peak:", in: lines.map { $0.trimmingCharacters(in: .whitespaces) }) {
            result.append(ProfileHighlight(label: "Peak footprint", value: peak))
        }
        struct Category { var name: String; var dirty: UInt64; var reclaimable: UInt64 }
        var categories: [Category] = []
        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // "336 KB  0 B  0 B  8  MALLOC metadata": three size pairs, a region count, then the name.
            guard parts.count >= 8, let dirty = bytes(parts[0] + parts[1]), let reclaimable = bytes(parts[4] + parts[5]),
                  Int(parts[6]) != nil else { continue }
            let name = parts.dropFirst(7).joined(separator: " ")
            guard name != "TOTAL" else { continue }
            categories.append(Category(name: name, dirty: dirty, reclaimable: reclaimable))
        }
        for category in categories.sorted(by: { $0.dirty > $1.dirty }).prefix(highlightRows) where category.dirty > 0 {
            result.append(ProfileHighlight(
                label: "Dirty: \(category.name)",
                value: size(category.dirty) + (category.reclaimable > 0 ? " (\(size(category.reclaimable)) reclaimable)" : "")
            ))
        }
        return result
    }

    // MARK: vmmap

    private static func vmmap(_ lines: [String]) -> [ProfileHighlight] {
        var result: [ProfileHighlight] = []
        if let value = value(after: "Physical footprint:", in: lines) { result.append(ProfileHighlight(label: "Physical footprint", value: value)) }
        if let value = value(after: "Physical footprint (peak):", in: lines) { result.append(ProfileHighlight(label: "Peak footprint", value: value)) }
        if let value = value(after: "Writable regions:", in: lines) { result.append(ProfileHighlight(label: "Writable regions", value: value)) }

        struct Region { var name: String; var virtual: UInt64; var dirty: UInt64; var swapped: UInt64 }
        var regions: [Region] = []
        var inTable = false
        for line in lines {
            if line.hasPrefix("REGION TYPE") { inTable = true; continue }
            if line.hasPrefix("MALLOC ZONE") { break }
            guard inTable, !line.hasPrefix("="), !line.hasPrefix("TOTAL") else { continue }
            // Region names contain single spaces; the columns are separated by at least two.
            let columns = line.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard columns.count >= 2 else { continue }
            let numbers = columns.dropFirst().joined(separator: " ").split(separator: " ").map(String.init)
            guard numbers.count >= 4, let virtual = bytes(numbers[0]), let dirty = bytes(numbers[2]), let swapped = bytes(numbers[3]) else { continue }
            regions.append(Region(name: columns[0], virtual: virtual, dirty: dirty, swapped: swapped))
        }
        for region in regions.sorted(by: { $0.dirty + $0.swapped > $1.dirty + $1.swapped }).prefix(highlightRows) where region.dirty + region.swapped > 0 {
            var detail = "\(size(region.dirty)) dirty"
            if region.swapped > 0 { detail += ", \(size(region.swapped)) swapped" }
            detail += " of \(size(region.virtual)) virtual"
            result.append(ProfileHighlight(label: region.name, value: detail, severity: region.swapped > 0 ? .notable : .normal))
        }
        return result
    }

    // MARK: heap

    private static func heap(_ lines: [String]) -> [ProfileHighlight] {
        var result: [ProfileHighlight] = []
        if let line = lines.first(where: { $0.hasPrefix("All zones:") && $0.contains("bytes)") }) {
            result.append(ProfileHighlight(label: "Live allocations", value: String(line.dropFirst("All zones:".count)).trimmingCharacters(in: .whitespaces)))
        }
        if let found = value(after: "Found:", in: lines) {
            result.append(ProfileHighlight(label: "Classes", value: found.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")))
        }
        struct Row { var count: UInt64; var bytes: UInt64; var name: String }
        var rows: [Row] = []
        var inTable = false
        for line in lines {
            if line.contains("CLASS_NAME") { inTable = true; continue }
            guard inTable else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, first.isNumber else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 4, let count = UInt64(parts[0]), let total = UInt64(parts[1]) else { continue }
            rows.append(Row(count: count, bytes: total, name: parts[3].trimmingCharacters(in: .whitespaces).components(separatedBy: "  ").first ?? parts[3]))
        }
        for row in rows.sorted(by: { $0.bytes > $1.bytes }).prefix(highlightRows) {
            result.append(ProfileHighlight(label: row.name.trimmingCharacters(in: .whitespaces), value: "\(size(row.bytes)) in \(row.count.formatted()) objects"))
        }
        return result
    }

    // MARK: leaks

    private static func leaks(_ lines: [String]) -> [ProfileHighlight] {
        var result: [ProfileHighlight] = []
        for line in lines {
            guard line.hasPrefix("Process ") else { continue }
            let text = line.firstIndex(of: ":").map { line[line.index(after: $0)...].trimmingCharacters(in: .whitespaces) } ?? line
            if text.contains("leaks for") || text.contains("leak for") {
                let clean = text.hasPrefix("0 leaks")
                result.append(ProfileHighlight(label: "Leaks", value: text, severity: clean ? .normal : .alert))
            } else if text.contains("nodes malloced") {
                result.append(ProfileHighlight(label: "Scanned", value: text))
            } else if text.contains("not debuggable") {
                result.append(ProfileHighlight(label: "Limited scan", value: "Process is protected; only read-only memory could be inspected.", severity: .notable))
            }
        }
        let roots = lines.filter { $0.contains("ROOT LEAK") || $0.contains("ROOT CYCLE") }
        for root in roots.prefix(highlightRows) {
            result.append(ProfileHighlight(label: "Leak", value: root.trimmingCharacters(in: .whitespaces), severity: .alert))
        }
        if roots.count > highlightRows {
            result.append(ProfileHighlight(label: "More leaks", value: "\(roots.count - highlightRows) further roots in the full output", severity: .notable))
        }
        return result
    }

    // MARK: sample

    private static func sample(_ lines: [String]) -> [ProfileHighlight] {
        guard let start = lines.firstIndex(where: { $0.hasPrefix("Sort by top of stack") }) else { return [] }
        var rows: [(name: String, count: Int)] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("Binary Images") { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.lastIndex(of: " "), let count = Int(trimmed[trimmed.index(after: space)...]) else { continue }
            rows.append((String(trimmed[..<space]).trimmingCharacters(in: .whitespaces), count))
        }
        let total = rows.reduce(0) { $0 + $1.count }
        return rows.prefix(highlightRows).map {
            let share = total > 0 ? " (\(Int((Double($0.count) / Double(total) * 100).rounded()))%)" : ""
            return ProfileHighlight(label: $0.name, value: "\($0.count) samples\(share)")
        }
    }

    /// First line worth showing when a tool fails.
    static func failureMessage(tool: ProfileTool, status: Int32, error: String, timedOut: Bool) -> String {
        if timedOut { return "\(tool.executable) did not finish within \(Int(tool.timeout)) seconds and was stopped." }
        let lines = error.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let privilege = lines.first(where: { $0.contains("appropriate privileges") }) {
            let reason = privilege.components(separatedBy: "]: ").last ?? privilege
            return "\(reason) Smack runs as your user, so root-owned and other users' processes cannot be inspected."
        }
        return lines.first ?? "\(tool.executable) exited with status \(status)."
    }
}

// MARK: - Runner

enum ProfileRunner {
    struct Result: Sendable {
        var status: Int32
        var output: String
        var error: String
        var timedOut: Bool
        var truncated: Bool
    }

    /// Output kept per run; heap and vmmap dumps of large processes can be tens of megabytes.
    static let outputLimit = 16 * 1024 * 1024

    static func run(_ tool: ProfileTool, pid: Int32) async -> ProfileReport {
        let started = Date()
        let result = await execute(tool.executable, tool.arguments(pid: pid), timeout: tool.timeout)
        let failed = result.timedOut || !tool.succeeded(status: result.status)
        return ProfileReport(
            tool: tool,
            pid: pid,
            output: result.output,
            failure: failed ? ProfileParser.failureMessage(tool: tool, status: result.status, error: result.error, timedOut: result.timedOut) : nil,
            duration: Date().timeIntervalSince(started),
            highlights: failed ? [] : ProfileParser.highlights(for: tool, output: result.output),
            truncated: result.truncated
        )
    }

#if SMACK_APP_STORE
    static func execute(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> Result {
        Result(status: -1, output: "", error: "Unavailable in the App Store build.", timedOut: false, truncated: false)
    }
#else
    private final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private(set) var timedOut = false

        func attach(_ process: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return false }
            self.process = process
            return true
        }

        func cancel() { stop(timedOut: false) }

        func stop(timedOut: Bool) {
            lock.lock()
            cancelled = true
            if timedOut { self.timedOut = true }
            let process = process
            lock.unlock()
            if let process, process.isRunning { process.terminate() }
        }
    }

    static func execute(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> Result {
        let handle = Handle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: executeBlocking(executable, arguments, timeout: timeout, handle: handle))
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    private static func executeBlocking(_ executable: String, _ arguments: [String], timeout: TimeInterval, handle: Handle) -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return Result(status: -1, output: "", error: "\(executable) is not installed.", timedOut: false, truncated: false)
        }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do {
            guard handle.attach(process) else {
                return Result(status: -1, output: "", error: "Cancelled.", timedOut: false, truncated: false)
            }
            try process.run()
        } catch {
            return Result(status: -1, output: "", error: error.localizedDescription, timedOut: false, truncated: false)
        }
        let watchdog = DispatchWorkItem { handle.stop(timedOut: true) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Drain stderr concurrently so a full pipe cannot stall the child while stdout is read.
        nonisolated(unsafe) var errorData = Data()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: group) {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
        }
        var outputData = Data()
        var truncated = false
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            let room = outputLimit - outputData.count
            if chunk.count > room { truncated = true }
            if room > 0 { outputData.append(chunk.prefix(room)) }
        }
        group.wait()
        process.waitUntilExit()
        watchdog.cancel()
        return Result(
            status: process.terminationStatus,
            output: String(decoding: outputData, as: UTF8.self),
            error: String(decoding: errorData, as: UTF8.self),
            timedOut: handle.timedOut,
            truncated: truncated
        )
    }
#endif
}

// MARK: - Termination

/// Sends a signal to the processes of an application, but only to the ones the user was shown.
enum ProcessTerminator {
    struct Failure: Sendable, Equatable {
        var pid: Int32
        var code: Int32

        var message: String {
            switch code {
            case EPERM: "\(pid): not permitted (owned by root or another user)"
            default: "\(pid): \(String(cString: strerror(code)))"
            }
        }
    }

    struct Outcome: Sendable, Equatable {
        var signaled: [Int32] = []
        /// Already gone, reused by another process, Smack itself or a system pid.
        var skipped: [Int32] = []
        var failures: [Failure] = []

        var summary: String {
            var parts: [String] = []
            if !signaled.isEmpty { parts.append("Signaled \(signaled.count) process\(signaled.count == 1 ? "" : "es").") }
            if !skipped.isEmpty { parts.append("Skipped \(skipped.count) (already exited or protected).") }
            if !failures.isEmpty { parts.append("Failed: " + failures.map(\.message).joined(separator: "; ") + ".") }
            return parts.isEmpty ? "Nothing to do." : parts.joined(separator: " ")
        }
    }

    /// - Parameters:
    ///   - targets: identities captured when the confirmation was shown.
    ///   - current: identities running now; a target whose pid was reused has a different start time and is skipped.
    ///   - send: delivers a signal and returns 0 or an errno.
    static func terminate(
        targets: [ProcessIdentity],
        current: [ProcessIdentity],
        force: Bool,
        selfPID: Int32 = getpid(),
        send: (Int32, Int32) -> Int32 = { kill($0, $1) == 0 ? 0 : errno }
    ) -> Outcome {
        let alive = Set(current)
        var outcome = Outcome()
        for target in targets {
            guard alive.contains(target), target.pid > 1, target.pid != selfPID else {
                outcome.skipped.append(target.pid)
                continue
            }
            switch send(target.pid, force ? SIGKILL : SIGTERM) {
            case 0: outcome.signaled.append(target.pid)
            case ESRCH: outcome.skipped.append(target.pid)
            case let code: outcome.failures.append(Failure(pid: target.pid, code: code))
            }
        }
        return outcome
    }
}
