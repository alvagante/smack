import Darwin
import Foundation
import SmackIPC
import Synchronization

/// Each connection owns its capture task; the gate limits tracing across all clients.
final class FileActivityCapture: Sendable {
    private static let active = Mutex(false)
    private struct State {
        var task: Task<Void, Never>?
        var disconnected = false
    }
    private let state = Mutex(State())
    static let outputLimit = 1_048_576

    static func isCurrent(pid: Int32, startTime: Double) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000 == startTime
    }

    func cancel() {
        state.withLock {
            $0.disconnected = true
            $0.task?.cancel()
        }
    }

    func start(pid: Int32, startTime: Double, reply: @escaping (Data?, String?) -> Void) {
        let completion = Reply(reply)
        let accepted = state.withLock { state in
            guard !state.disconnected else { return false }
            let available = Self.active.withLock { active in
                guard !active else { return false }
                active = true
                return true
            }
            guard available else { return false }
            state.task = Task.detached(priority: .utility) { [self] in
                defer {
                    self.state.withLock { $0.task = nil }
                    Self.active.withLock { $0 = false }
                }
                let result = await Self.capture(pid: pid, startTime: startTime)
                completion.call(try? JSONEncoder().encode(result))
            }
            return true
        }
        if !accepted { reply(nil, "A capture is already running or the client disconnected.") }
    }

    private final class Reply: @unchecked Sendable {
        let reply: (Data?, String?) -> Void
        init(_ reply: @escaping (Data?, String?) -> Void) { self.reply = reply }
        func call(_ data: Data?) { reply(data, nil) }
    }

    private static func capture(pid: Int32, startTime: Double) async -> FileActivityPayload {
        guard isCurrent(pid: pid, startTime: startTime) else {
            return FileActivityPayload(error: "The process exited or its PID was reused.")
        }
        let result = await Subprocess.run("/usr/bin/fs_usage", ["-w", "-f", "filesys", "-t", "5", String(pid)],
                                          timeout: 7, outputLimit: outputLimit)
        guard isCurrent(pid: pid, startTime: startTime) else {
            return FileActivityPayload(error: "The process exited during capture; the trace was discarded to avoid PID reuse.")
        }
        if result.cancelled { return FileActivityPayload(error: "Capture cancelled after client disconnection.") }
        if result.timedOut { return FileActivityPayload(error: "File tracing exceeded its deadline and was stopped.") }
        let text = result.output + result.error
        if result.status != 0 {
            return FileActivityPayload(error: text.isEmpty ? "File tracing failed (status \(result.status))." : String(text.prefix(2_000)))
        }
        var bounded = Data(text.utf8).prefix(outputLimit)
        while String(data: bounded, encoding: .utf8) == nil { bounded = bounded.dropLast() }
        return FileActivityPayload(output: String(decoding: bounded, as: UTF8.self),
                                   error: result.truncated || text.utf8.count > outputLimit
                                   ? "Output limited to 1 MB; capture is incomplete." : nil)
    }
}
