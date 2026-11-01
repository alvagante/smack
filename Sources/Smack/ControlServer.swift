#if !SMACK_APP_STORE
import Foundation
import Darwin
import SmackIPC

/// The listener never polls. Blocking reads/writes run off the main actor with bounded peers.
final class ControlServer: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var clients: Set<Int32> = []
    private var tasks: [Int32: Task<Void, Never>] = [:]
    private var stopped = false
    private let directoryFD: Int32
    private let socketIdentity: stat
    private let socketName: String
    let path: String

    init(paths: [String] = ControlSocket.paths(),
         stream: (@Sendable (ControlRequest) async -> ControlSubscription)? = nil,
         handler: @escaping @Sendable (ControlRequest) async -> ControlResponse) throws {
        guard let path = paths.first else { throw ControlError.unavailable }
        _ = try ControlSocket.address(path)
        self.path = path
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let parent = try Self.secureDirectory(directory)
        var retainedParent = false
        defer { if !retainedParent { close(parent) } }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK else {
                throw ControlError.unavailable
            }
            do {
                let active = try ControlSocket.connect(path)
                close(active)
                throw ControlError.unavailable
            } catch let error as POSIXError where error.code == .ECONNREFUSED {
                var current = stat()
                guard fstatat(parent, URL(fileURLWithPath: path).lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0, current.st_uid == geteuid(),
                      current.st_mode & S_IFMT == S_IFSOCK, current.st_dev == info.st_dev,
                      current.st_ino == info.st_ino, unlinkat(parent, URL(fileURLWithPath: path).lastPathComponent, 0) == 0 else { throw ControlError.unavailable }
            }
        } else if errno != ENOENT {
            throw ControlError.unavailable
        }
        var pinned = stat()
        var named = stat()
        guard fstat(parent, &pinned) == 0, lstat(directory, &named) == 0,
              pinned.st_dev == named.st_dev, pinned.st_ino == named.st_ino else { throw ControlError.unavailable }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.unavailable }
        ControlSocket.configure(fd)
        var address = try ControlSocket.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(fd); throw ControlError.unavailable }
        guard lstat(directory, &named) == 0, named.st_dev == pinned.st_dev, named.st_ino == pinned.st_ino,
              fchmodat(parent, URL(fileURLWithPath: path).lastPathComponent, 0o600, AT_SYMLINK_NOFOLLOW) == 0, listen(fd, Int32(ControlProtocol.clientLimit)) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { close(fd); throw ControlError.unavailable }
        guard lstat(path, &info) == 0 else { close(fd); throw ControlError.unavailable }
        directoryFD = parent
        socketIdentity = info
        socketName = URL(fileURLWithPath: path).lastPathComponent
        retainedParent = true
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                self.lock.lock()
                let stopped = self.stopped
                self.lock.unlock()
                if stopped { break }
                let peer = accept(fd, nil, nil)
                guard peer >= 0 else { break }
                var uid: uid_t = 0
                var gid: gid_t = 0
                guard fcntl(peer, F_SETFL, 0) == 0,
                      getpeereid(peer, &uid, &gid) == 0, uid == geteuid(), self.reserve(peer) else {
                    close(peer); continue
                }
                ControlSocket.configure(peer)
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let data = try ControlSocket.readLine(from: peer, limit: ControlProtocol.requestLimit)
                        let request = try ControlRequest.decode(data)
                        self.run(peer) {
                            defer { self.release(peer) }
                            do {
                                try Task.checkCancellation()
                                if !ControlProtocol.supports(request.version) {
                                    try ControlSocket.write(try ControlResponse(error: .unsupportedVersion,
                                        requestedVersion: request.version).encoded(), to: peer)
                                } else if request.follow == true, let stream {
                                    let subscription = await stream(request)
                                    defer { subscription.cancel() }
                                    for try await response in subscription.responses {
                                        try Task.checkCancellation()
                                        try ControlSocket.write(try response.encoded(version: request.version), to: peer)
                                    }
                                } else {
                                    let response = await handler(request)
                                    let bytes = try (try? response.encoded(version: request.version)) ??
                                        ControlResponse(error: .responseTooLarge).encoded(version: request.version)
                                    try ControlSocket.write(bytes, to: peer)
                                }
                            } catch {
                                guard let error = error as? ControlError else { return }
                                if let bytes = try? ControlResponse(error: error).encoded() {
                                    try? ControlSocket.write(bytes, to: peer)
                                }
                            }
                        }
                    } catch {
                        defer { self.release(peer) }
                        if let bytes = try? ControlResponse(error: .invalidRequest).encoded() {
                            try? ControlSocket.write(bytes, to: peer)
                        }
                    }
                }
            }
        }
        source.resume()
    }


    /// Walk from root using descriptor-relative operations. Symlink ancestors cannot redirect mkdir/chmod.
    private static func secureDirectory(_ path: String) throws -> Int32 {
        var physical = path
        // Darwin system aliases, never arbitrary user-controlled symlinks.
        for alias in ["/tmp", "/var"] where physical == alias || physical.hasPrefix(alias + "/") {
            physical = "/private" + physical
        }
        guard physical.hasPrefix("/"), !physical.split(separator: "/").contains("..") else {
            throw ControlError.unavailable
        }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ControlError.unavailable }
        do {
            let parts = physical.split(separator: "/").map(String.init)
            for (index, part) in parts.enumerated() {
                var next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0, errno == ENOENT {
                    guard mkdirat(fd, part, 0o700) == 0 else { throw ControlError.unavailable }
                    next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw ControlError.unavailable }
                var info = stat()
                let valid = fstat(next, &info) == 0 && (info.st_uid == 0 || info.st_uid == geteuid())
                    && (info.st_mode & 0o022 == 0 || (info.st_uid == 0 && info.st_mode & S_ISVTX != 0))
                guard valid else { close(next); throw ControlError.unavailable }
                close(fd); fd = next
                if index == parts.count - 1 {
                    guard info.st_uid == geteuid(), fchmod(fd, 0o700) == 0 else { throw ControlError.unavailable }
                }
            }
            return fd
        } catch { close(fd); throw error }
    }

    var activeClientCount: Int {
        lock.lock(); defer { lock.unlock() }
        return clients.count
    }

    private func reserve(_ peer: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, clients.count < ControlProtocol.clientLimit else { return false }
        clients.insert(peer); return true
    }
    private func run(_ peer: Int32, operation: @escaping @Sendable () async -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else {
            clients.remove(peer)
            close(peer)
            return
        }
        // Register under the same lock used by release, before the descriptor can be reused.
        tasks[peer] = Task.detached(operation: operation)
    }

    private func release(_ peer: Int32) {
        lock.lock(); defer { lock.unlock() }
        tasks[peer] = nil
        clients.remove(peer)
        close(peer)
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        for peer in clients { shutdown(peer, SHUT_RDWR) }
        for task in tasks.values { task.cancel() }
        source.cancel()
        var current = stat()
        if fstatat(directoryFD, socketName, &current, AT_SYMLINK_NOFOLLOW) == 0,
           current.st_dev == socketIdentity.st_dev, current.st_ino == socketIdentity.st_ino,
           current.st_mode & S_IFMT == S_IFSOCK, current.st_uid == geteuid() {
            _ = unlinkat(directoryFD, socketName, 0)
        }
    }
    deinit { stop(); close(directoryFD) }
}
#endif
