import Foundation
import Synchronization
import SmackIPC

/// Talks to the root daemon over XPC. Any failure (helper not installed, not approved,
/// connection dropped, malformed reply, timeout) returns nil so callers fall back to the
/// unprivileged collectors instead of showing an error.
/// `@unchecked`: `NSXPCConnection` is not Sendable, so the connection lives behind `lock`, which guards every
/// access to the mutable state below.
final class PrivilegedSamplingClient: PrivilegedSamplingProviding, @unchecked Sendable {
    // NSXPCConnection supports concurrent invalidation; this reference is immutable.
    private struct ConnectionReference: @unchecked Sendable { let value: NSXPCConnection }
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var available = false
    private var versionTask: Task<Int, Never>?
    private let connectionFactory: @Sendable () -> NSXPCConnection
    private let timeoutOverride: TimeInterval?

    init(connectionFactory: @escaping @Sendable () -> NSXPCConnection = {
        NSXPCConnection(machServiceName: SmackIPC.machServiceName, options: .privileged)
    }, timeoutOverride: TimeInterval? = nil) {
        self.connectionFactory = connectionFactory
        self.timeoutOverride = timeoutOverride
    }

    func protocolVersion() async -> Int {
        guard isAvailable() else { return 0 }
        return await negotiatedVersion().value
    }

    private func negotiatedVersion() -> Task<Int, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let versionTask { return versionTask }
        let task = Task { [weak self] in
            guard let self else { return 1 }
            return await self.readVersion()
        }
        versionTask = task
        return task
    }

    private func readVersion() async -> Int {
        // XPC optional selectors are not capability discovery: sending an unknown
        // selector can terminate a v1 daemon. Use its existing reply shape instead.
        let snapshot: ProcessSnapshotPayload? = await request(timeout: 2) { proxy, reply in proxy.collectSnapshot(reply: reply) }
        return snapshot?.helperProtocolVersion ?? 1
    }

    func dumpBackgroundTasks() async -> String? {
        guard await protocolVersion() >= 2, !Task.isCancelled else { return nil }
        return await request(timeout: 6) { proxy, reply in proxy.dumpBackgroundTasks?(reply: reply) }
    }

    func listConfigurationProfiles() async -> String? {
        guard await protocolVersion() >= 2, !Task.isCancelled else { return nil }
        return await request(timeout: 6) { proxy, reply in proxy.listConfigurationProfiles?(reply: reply) }
    }

    /// The controller sets this only when the daemon reports `.enabled`. Without it every
    /// sample would wait for a connection that cannot exist.
    func setAvailable(_ value: Bool) {
        lock.lock()
        available = value
        let stale = value ? nil : connection
        let staleVersion = value ? nil : versionTask
        if !value { connection = nil; versionTask = nil }
        lock.unlock()
        staleVersion?.cancel()
        stale?.invalidate()
    }

    func collectSnapshot() async -> ProcessSnapshotPayload? {
        await request(timeout: 3) { proxy, reply in
            proxy.collectSnapshot(reply: reply)
        }
    }

    func collectInventory(pid: Int32, startTime: Date) async -> InventoryPayload? {
        await request(timeout: 6) { proxy, reply in
            proxy.collectInventory(pid: pid, startTime: startTime.timeIntervalSince1970, reply: reply)
        }
    }

    func captureFileActivity(pid: Int32, startTime: Date) async -> FileActivityPayload? {
        await request(timeout: 10) { proxy, reply in
            proxy.captureFileActivity(pid: pid, startTime: startTime.timeIntervalSince1970, reply: reply)
        }
    }

    func collectNetworkPorts() async -> SocketCollection? {
        await request(timeout: 6) { proxy, reply in
            proxy.collectNetworkPorts(reply: reply)
        }
    }

    func startStorageScan() async -> Bool? {
        await request(timeout: 6) { proxy, reply in proxy.startStorageScan(reply: reply) }
    }

    func storageScanStatus() async -> StorageScanSnapshot? {
        await request(timeout: 30) { proxy, reply in proxy.storageScanStatus(reply: reply) }
    }

    func cancelStorageScan() async {
        let _: Bool? = await request(timeout: 6) { proxy, reply in proxy.cancelStorageScan(reply: reply) }
    }

    private func request<T: Decodable & Sendable>(
        timeout: TimeInterval,
        _ start: (SmackPrivilegedSampling, @escaping (Data?, String?) -> Void) -> Void
    ) async -> T? {
        guard isAvailable(), !Task.isCancelled else { return nil }
        let connection = currentConnection()
        let completion = Completion<T>()
        let reference = ConnectionReference(value: connection)
        return await withTaskCancellationHandler {
          await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            completion.attach(continuation)
            guard !Task.isCancelled else { completion.finish(nil); return }
            let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
                self?.invalidate(connection)
                completion.finish(nil)
            } as? SmackPrivilegedSampling
            guard let proxy else {
                completion.finish(nil)
                return
            }
            start(proxy) { data, _ in
                completion.finish(data.flatMap { try? JSONDecoder().decode(T.self, from: $0) })
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + (timeoutOverride ?? timeout)) {
                completion.finish(nil)
            }
          }
        } onCancel: {
            completion.finish(nil)
            // Invalidating also cancels the daemon's in-flight probe on this connection.
            self.invalidate(reference.value)
        }
    }

    private func isAvailable() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return available
    }

    private func currentConnection() -> NSXPCConnection {
        lock.lock()
        let existing = connection
        lock.unlock()
        if let existing { return existing }

        // The daemon lives in the system bootstrap whichever way it was installed.
        let new = connectionFactory()
        new.remoteObjectInterface = NSXPCInterface(with: SmackPrivilegedSampling.self)
        new.invalidationHandler = { [weak self, weak new] in
            guard let new else { return }
            self?.invalidate(new)
        }
        new.interruptionHandler = { [weak self, weak new] in
            guard let new else { return }
            self?.invalidate(new)
        }

        lock.lock()
        if let existing = connection {
            lock.unlock()
            new.invalidate()
            return existing
        }
        connection = new
        lock.unlock()
        new.resume()
        return new
    }

    private func invalidate(_ connection: NSXPCConnection) {
        lock.lock()
        if self.connection === connection {
            self.connection = nil
            versionTask = nil
        }
        lock.unlock()
        connection.invalidate()
    }

    /// A continuation can be resumed only once, but the reply and the timeout race.
    private final class Completion<T: Sendable>: Sendable {
        private struct State {
            var continuation: CheckedContinuation<T?, Never>?
            var finished = false
            var value: T?
        }
        private let state = Mutex(State())

        func attach(_ continuation: CheckedContinuation<T?, Never>) {
            let completed = state.withLock { stored -> (Bool, T?) in
                if stored.finished {
                    defer { stored.value = nil }
                    return (true, stored.value)
                }
                stored.continuation = continuation
                return (false, nil)
            }
            if completed.0 { continuation.resume(returning: completed.1) }
        }

        func finish(_ value: T?) {
            let continuation = state.withLock { stored -> CheckedContinuation<T?, Never>? in
                guard !stored.finished else { return nil }
                stored.finished = true
                if stored.continuation == nil { stored.value = value }
                defer { stored.continuation = nil }
                return stored.continuation
            }
            continuation?.resume(returning: value)
        }
    }
}
