import Foundation
import Darwin

public enum ControlSocket {
    public static func paths(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                             temporary: String = NSTemporaryDirectory(), uid: uid_t = geteuid()) -> [String] {
        [home + "/Library/Application Support/Smack/control.sock",
         URL(fileURLWithPath: temporary).appendingPathComponent("smack-\(uid)/control.sock").path]
            .filter { !$0.utf8.contains(0) && $0.utf8.count <= 103 }
    }

    public static func address(_ path: String) throws -> sockaddr_un {
        guard !path.utf8.contains(0), path.utf8.count <= 103 else { throw ControlError.invalidRequest }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: path.utf8)
        }
        return address
    }

    public static func connect(_ path: String) throws -> Int32 {
        var address = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        configure(fd)
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { close(fd); throw POSIXError(.EIO) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            let code = errno
            guard code == EINPROGRESS else { close(fd); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: error))
            let readiness = poll(&descriptor, 1, 5000)
            guard readiness > 0 else {
                let code = readiness == 0 ? ETIMEDOUT : errno
                close(fd); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else {
                let code = errno
                close(fd); throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            guard error == 0 else {
                close(fd); throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            }
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid(),
              fcntl(fd, F_SETFL, 0) == 0 else { close(fd); throw POSIXError(.EACCES) }
        configure(fd)
        return fd
    }

    public static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }

    public static func write(_ data: Data, to fd: Int32) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try ready(fd, events: Int16(POLLOUT), deadline: deadline)
                let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, MSG_DONTWAIT)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
    }

    private static func ready(_ fd: Int32, events: Int16, deadline: Double) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw POSIXError(.ETIMEDOUT) }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000, 5000)))
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw POSIXError(.ETIMEDOUT) }
            return
        }
    }

    public static func readLine(from fd: Int32, limit: Int) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= limit {
            try ready(fd, events: Int16(POLLIN), deadline: deadline)
            let count = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - data.count))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ControlError.invalidRequest }
            if let newline = buffer[..<count].firstIndex(of: 10) {
                // One request per connection, reject pipelining rather than ignoring an action.
                guard newline == count - 1 else { throw ControlError.invalidRequest }
                data.append(contentsOf: buffer[..<newline])
                guard data.count <= limit else { throw ControlError.invalidRequest }
                return data
            }
            data.append(contentsOf: buffer[..<count])
        }
        throw ControlError.invalidRequest
    }
}

public struct ControlResponseReader {
    private var pending = Data()
    public init() {}
    public mutating func next(from fd: Int32) throws -> ControlResponse {
        while true {
            if let newline = pending.firstIndex(of: 10) {
                let line = pending[..<newline]
                let response = try JSONDecoder().decode(ControlResponse.self, from: line)
                pending.removeSubrange(...newline)
                return response
            }
            guard pending.count <= ControlProtocol.responseLimit else { throw ControlError.responseTooLarge }
            var bytes = [UInt8](repeating: 0, count: min(4096, ControlProtocol.responseLimit + 1 - pending.count))
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ControlError.unavailable }
            pending.append(contentsOf: bytes[..<count])
        }
    }
}
