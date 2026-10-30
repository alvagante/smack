import Foundation
import Synchronization

/// Runs a fixed executable with explicit arguments (never a shell) and collects its output, with an optional
/// timeout, an output cap and task cancellation. Pipe reads block, so they run on GCD rather than the
/// cooperative thread pool.
enum CommandRunner {
    struct Result: Sendable {
        var status: Int32
        var output: String
        var error: String
        var timedOut = false
        var truncated = false
        var cancelled = false

        static func unavailable(_ message: String) -> Result {
            Result(status: -1, output: "", error: message)
        }
    }

#if SMACK_APP_STORE
    static func run(
        _ executable: String,
        _ arguments: [String],
        input: String? = nil,
        timeout: TimeInterval? = nil,
        outputLimit: Int = .max,
        cancellable: Bool = true
    ) async -> Result {
        .unavailable("Unavailable in the App Store build.")
    }
#else
    /// Owns the running process so cancellation and the watchdog can stop it from any thread.
    private final class Handle: Sendable {
        private struct State {
            var process: Process?
            var cancelled = false
            var timedOut = false
        }

        private let state = Mutex(State())

        var timedOut: Bool { state.withLock { $0.timedOut } }
        var cancelled: Bool { state.withLock { $0.cancelled } }

        /// False when cancellation arrived before the process started.
        func attach(_ process: Process) -> Bool {
            state.withLock { state in
                guard !state.cancelled else { return false }
                state.process = process
                return true
            }
        }

        func stop(timedOut: Bool) {
            let process = state.withLock { state -> Process? in
                state.cancelled = true
                if timedOut { state.timedOut = true }
                return state.process
            }
            if let process, process.isRunning { process.terminate() }
        }
    }

    /// `cancellable: false` lets the command finish even if the calling task is cancelled, for commands that
    /// change state and must not be cut off halfway.
    static func run(
        _ executable: String,
        _ arguments: [String],
        input: String? = nil,
        timeout: TimeInterval? = nil,
        outputLimit: Int = .max,
        cancellable: Bool = true
    ) async -> Result {
        let handle = Handle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: runBlocking(
                        executable, arguments, input: input, timeout: timeout, outputLimit: outputLimit, handle: handle
                    ))
                }
            }
        } onCancel: {
            if cancellable { handle.stop(timedOut: false) }
        }
    }

    private static func runBlocking(
        _ executable: String,
        _ arguments: [String],
        input: String?,
        timeout: TimeInterval?,
        outputLimit: Int,
        handle: Handle
    ) -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return .unavailable("\(executable) is not installed.")
        }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let inputPipe = input.map { _ in Pipe() }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        guard handle.attach(process) else {
            return Result(status: -1, output: "", error: "Cancelled.", cancelled: true)
        }
        do {
            try process.run()
        } catch {
            return .unavailable(error.localizedDescription)
        }
        let watchdog = DispatchWorkItem { handle.stop(timedOut: true) }
        if let timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        }

        // Feed stdin and drain stderr concurrently, so neither a full pipe nor a slow reader can stall the child
        // while stdout is read.
        let group = DispatchGroup()
        if let inputPipe, let input {
            DispatchQueue.global(qos: .utility).async(group: group) {
                let writer = inputPipe.fileHandleForWriting
                // A child that exits without reading must yield EPIPE, not a SIGPIPE that ends Smack.
                _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
                try? writer.write(contentsOf: Data(input.utf8))
                try? writer.close()
            }
        }
        let errorData = Mutex(Data())
        DispatchQueue.global(qos: .utility).async(group: group) {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            errorData.withLock { $0 = data }
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
            error: errorData.withLock { String(decoding: $0, as: UTF8.self) },
            timedOut: handle.timedOut,
            truncated: truncated,
            cancelled: handle.cancelled && !handle.timedOut
        )
    }
#endif
}
