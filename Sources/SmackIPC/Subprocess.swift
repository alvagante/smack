import Darwin
import Foundation
import Synchronization

/// Shared by app commands and helper traces; the helper never exposes this API over XPC.
public enum Subprocess {
    public struct Result: Sendable {
        public var status: Int32
        public var output: String
        public var error: String
        public var timedOut = false
        public var truncated = false
        public var cancelled = false

        public init(status: Int32, output: String, error: String,
                    timedOut: Bool = false, truncated: Bool = false, cancelled: Bool = false) {
            self.status = status
            self.output = output
            self.error = error
            self.timedOut = timedOut
            self.truncated = truncated
            self.cancelled = cancelled
        }

        public static func unavailable(_ message: String) -> Result {
            Result(status: -1, output: "", error: message)
        }
    }

    private final class Cancellation: Sendable {
        let requested = Mutex(false)
    }

    public static func run(_ executable: String, _ arguments: [String], input: String? = nil,
                           timeout: TimeInterval? = nil, outputLimit: Int = .max,
                           cancellable: Bool = true) async -> Result {
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: runBlocking(executable, arguments, input: input,
                        timeout: timeout, outputLimit: outputLimit, cancellation: cancellation))
                }
            }
        } onCancel: {
            if cancellable { cancellation.requested.withLock { $0 = true } }
        }
    }

    private static func check(_ code: Int32) throws {
        if code != 0 { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    }

    private static func pipeDescriptors() throws -> [Int32] {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // GUI processes may have closed standard descriptors. Keep spawn sources above stderr.
        for index in descriptors.indices where descriptors[index] <= STDERR_FILENO {
            let duplicate = fcntl(descriptors[index], F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard duplicate >= 0 else {
                descriptors.forEach { if $0 >= 0 { _ = close($0) } }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            close(descriptors[index])
            descriptors[index] = duplicate
        }
        for fd in descriptors { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return descriptors
    }

    private static func runBlocking(_ executable: String, _ arguments: [String], input: String?,
                                    timeout: TimeInterval?, outputLimit: Int, cancellation: Cancellation) -> Result {
        if cancellation.requested.withLock({ $0 }) {
            return Result(status: -1, output: "", error: "Cancelled.", cancelled: true)
        }
        do {
            var output = try pipeDescriptors()
            defer { output.forEach { if $0 >= 0 { _ = close($0) } } }
            var errors = try pipeDescriptors()
            defer { errors.forEach { if $0 >= 0 { _ = close($0) } } }
            var stdin = try pipeDescriptors()
            defer { stdin.forEach { if $0 >= 0 { _ = close($0) } } }
            var actions: posix_spawn_file_actions_t?
            try check(posix_spawn_file_actions_init(&actions))
            defer { posix_spawn_file_actions_destroy(&actions) }
            var attributes: posix_spawnattr_t?
            try check(posix_spawnattr_init(&attributes))
            defer { posix_spawnattr_destroy(&attributes) }
            try check(posix_spawn_file_actions_adddup2(&actions, stdin[0], STDIN_FILENO))
            try check(posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO))
            try check(posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO))
            try check(posix_spawnattr_setpgroup(&attributes, 0))
            try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
            let argv = ([executable] + arguments).map { strdup($0) } + [nil]
            let env = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) } + [nil]
            defer { argv.forEach { free($0) }; env.forEach { free($0) } }
            var pid: pid_t = 0
            let spawned = argv.withUnsafeBufferPointer { argv in
                env.withUnsafeBufferPointer { env in
                    posix_spawn(&pid, executable, &actions, &attributes,
                                UnsafeMutablePointer(mutating: argv.baseAddress!),
                                UnsafeMutablePointer(mutating: env.baseAddress!))
                }
            }
            try check(spawned)
            // Only this worker owns descriptor closure. Polling avoids blocked readers/writers
            // retaining threads forever when descendants keep inherited descriptors open.
            return communicate(pid: pid, output: &output, errors: &errors, stdin: &stdin,
                               input: input, timeout: timeout, limit: max(0, outputLimit), cancellation: cancellation)
        } catch { return .unavailable(error.localizedDescription) }
    }

    private static func communicate(pid: pid_t, output: inout [Int32], errors: inout [Int32], stdin: inout [Int32],
                                    input: String?, timeout: TimeInterval?, limit: Int,
                                    cancellation: Cancellation) -> Result {
        let outFD = output[0], errFD = errors[0], inFD = stdin[1]
        close(output[1]); output[1] = -1
        close(errors[1]); errors[1] = -1
        close(stdin[0]); stdin[0] = -1
        for fd in [outFD, errFD, inFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        _ = fcntl(inFD, F_SETNOSIGPIPE, 1)
        let bytes = Array((input ?? "").utf8)
        var inputOffset = 0
        var outputData = Data(), errorData = Data()
        var truncated = false
        var openOutput = true, openError = true, openInput = true
        let started = ProcessInfo.processInfo.systemUptime
        var stopAt: TimeInterval?
        var exitedAt: TimeInterval?
        var timedOut = false, cancelled = false
        var exited = false
        var buffer = [UInt8](repeating: 0, count: 16_384)

        while true {
            let now = ProcessInfo.processInfo.systemUptime
            // WNOWAIT keeps the group leader's PID reserved until all group signals are sent.
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid {
                exited = true
                if exitedAt == nil { exitedAt = now }
            }
            if stopAt == nil {
                cancelled = cancellation.requested.withLock { $0 }
                timedOut = timeout.map { now - started >= $0 } ?? false
                // A successful parent can still leave pipes open in a background descendant.
                if let exitedAt, now - exitedAt >= 0.25, openOutput || openError { timedOut = true }
                if cancelled || timedOut { stopAt = now; _ = kill(-pid, SIGTERM) }
            }
            if let stopAt {
                if now - stopAt >= 0.25 { _ = kill(-pid, SIGKILL) }
                if (exited && !openOutput && !openError) || now - stopAt >= 0.5 {
                    _ = kill(-pid, SIGKILL)
                    break
                }
            } else if exited && !openOutput && !openError { break }

            if openInput && (inputOffset == bytes.count || exited || stopAt != nil) {
                close(stdin[1]); stdin[1] = -1
                openInput = false
            }
            var descriptors = [
                pollfd(fd: openOutput ? outFD : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: openError ? errFD : -1, events: Int16(POLLIN), revents: 0),
                pollfd(fd: openInput ? inFD : -1, events: Int16(POLLOUT), revents: 0)
            ]
            _ = poll(&descriptors, nfds_t(descriptors.count), 20)
            for index in 0..<2 where descriptors[index].revents != 0 {
                let count = read(descriptors[index].fd, &buffer, buffer.count)
                if count > 0 {
                    let room = limit - (index == 0 ? outputData.count : errorData.count)
                    if count > room { truncated = true }
                    if room > 0 {
                        if index == 0 { outputData.append(contentsOf: buffer.prefix(min(count, room))) }
                        else { errorData.append(contentsOf: buffer.prefix(min(count, room))) }
                    }
                } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    if index == 0 { openOutput = false } else { openError = false }
                }
            }
            if openInput && descriptors[2].revents != 0 {
                let count = bytes.withUnsafeBytes { pointer in
                    write(inFD, pointer.baseAddress!.advanced(by: inputOffset), min(16_384, bytes.count - inputOffset))
                }
                if count > 0 { inputOffset += count }
                else if count < 0 && errno != EAGAIN && errno != EINTR {
                    close(stdin[1]); stdin[1] = -1; openInput = false
                }
            }
        }
        var status: Int32 = 0
        if exited {
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        } else {
            // A kernel-stalled process must not delay the caller's deadline. Reap it when
            // the kernel eventually delivers SIGKILL, without retaining pipes or payloads.
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
        }
        let code = exited ? (status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f) : -1
        return Result(status: code, output: String(decoding: outputData, as: UTF8.self),
                      error: String(decoding: errorData, as: UTF8.self), timedOut: timedOut,
                      truncated: truncated, cancelled: cancelled)
    }
}
