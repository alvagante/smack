import Darwin
import Foundation
import SmackIPC
import Synchronization

/// A fixed, read-only trace; clients supply only the same PID/start-time pair as inventory.
enum FileActivityCapture {
    private static let active = Mutex(false)
    static let outputLimit = 1_048_576

    static func isCurrent(pid: Int32, startTime: Double) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000 == startTime
    }

    /// Calls the reply on a utility queue; the trace always expires after five seconds.
    static func start(pid: Int32, startTime: Double, reply: @escaping (Data?, String?) -> Void) {
        let accepted = active.withLock { active in
            if active { return false }
            active = true
            return true
        }
        guard accepted else { reply(nil, "A file activity capture is already running."); return }
        let completion = Reply(reply)
        DispatchQueue.global(qos: .utility).async {
            defer { active.withLock { $0 = false } }
            let result = capture(pid: pid, startTime: startTime)
            completion.call(try? JSONEncoder().encode(result))
        }
    }

    private final class Reply: @unchecked Sendable {
        let reply: (Data?, String?) -> Void
        init(_ reply: @escaping (Data?, String?) -> Void) { self.reply = reply }
        func call(_ data: Data?) { reply(data, nil) }
    }

    private static func capture(pid: Int32, startTime: Double) -> FileActivityPayload {
        guard isCurrent(pid: pid, startTime: startTime) else {
            return FileActivityPayload(error: "The process exited or its PID was reused.")
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/fs_usage")
        process.arguments = ["-w", "-f", "filesys", "-t", "5", String(pid)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return FileActivityPayload(error: error.localizedDescription) }
        var bytes = Data()
        var truncated = false
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            let room = outputLimit - bytes.count
            if chunk.count > room { truncated = true }
            if room > 0 { bytes.append(chunk.prefix(room)) }
        }
        process.waitUntilExit()
        guard isCurrent(pid: pid, startTime: startTime) else {
            return FileActivityPayload(error: "The process exited during capture; the trace was discarded to avoid PID reuse.")
        }
        let text = String(decoding: bytes, as: UTF8.self)
        if process.terminationStatus != 0 {
            return FileActivityPayload(error: text.isEmpty ? "File tracing failed (status \(process.terminationStatus))." : String(text.prefix(2_000)))
        }
        return FileActivityPayload(output: text, error: truncated ? "Output limited to 1 MB; capture is incomplete." : nil)
    }
}

