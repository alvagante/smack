import Foundation
import Synchronization
import SmackIPC

/// Talks to the root daemon over XPC. Any failure (helper not installed, not approved,
/// connection dropped, malformed reply, timeout) returns nil so callers fall back to the
/// unprivileged collectors instead of showing an error.
/// `@unchecked`: `NSXPCConnection` is not Sendable, so the connection lives behind `lock`, which guards every
/// access to the mutable state below.
final class PrivilegedSamplingClient: PrivilegedSamplingProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var available = false

    /// The controller sets this only when the daemon reports `.enabled`. Without it every
    /// sample would wait for a connection that cannot exist.
    func setAvailable(_ value: Bool) {
        lock.lock()
        available = value
        let stale = value ? nil : connection
        if !value { connection = nil }
        lock.unlock()
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
        guard isAvailable() else { return nil }
        let connection = currentConnection()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let completion = Completion(continuation: continuation)
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
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                completion.finish(nil)
            }
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
        let new = NSXPCConnection(machServiceName: SmackIPC.machServiceName, options: .privileged)
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
        }
        lock.unlock()
        connection.invalidate()
    }

    /// A continuation can be resumed only once, but the reply and the timeout race.
    private final class Completion<T: Sendable>: Sendable {
        private let continuation: Mutex<CheckedContinuation<T?, Never>?>

        init(continuation: CheckedContinuation<T?, Never>) {
            self.continuation = Mutex(continuation)
        }

        func finish(_ value: T?) {
            let continuation = self.continuation.withLock { stored in
                defer { stored = nil }
                return stored
            }
            continuation?.resume(returning: value)
        }
    }
}
