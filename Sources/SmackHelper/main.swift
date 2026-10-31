import Foundation
import Synchronization
import SmackIPC
import os

private let logger = Logger(subsystem: SmackIPC.helperIdentifier, category: "sampling")

/// The daemon returns read-only process and directory metadata. It never accepts a path or a
/// command. `collectInventory` accepts a PID plus start time, so an accepted client can list
/// open files, sockets, threads, and loaded images of any process, root processes included.
/// That is why connections are restricted to the signed Smack app run by an administrator.
final class PrivilegedSamplingService: NSObject, SmackPrivilegedSampling, Sendable {
    private let scan = Mutex<StorageScanJob?>(nil)

    func stopScan() {
        scan.withLock { $0?.cancel() }
    }

    func startStorageScan(reply: @escaping (Data?, String?) -> Void) {
        let job = scan.withLock { scan -> StorageScanJob? in
            if let scan, !scan.status().finished { return nil }
            let job = StorageScanJob(root: "/")
            scan = job
            return job
        }
        guard let job else {
            encode(false, reply: reply)
            return
        }
        DispatchQueue.global(qos: .utility).async { job.run() }
        encode(true, reply: reply)
    }

    func storageScanStatus(reply: @escaping (Data?, String?) -> Void) {
        let status = scan.withLock { scan -> StorageScanSnapshot? in
            let status = scan?.status()
            // The app owns the completed tree after this reply.
            if status?.finished == true { scan = nil }
            return status
        }
        if let status { encode(status, reply: reply) }
        else { reply(nil, "No storage scan is active.") }
    }

    func cancelStorageScan(reply: @escaping (Data?, String?) -> Void) {
        stopScan()
        encode(true, reply: reply)
    }

    func collectSnapshot(reply: @escaping (Data?, String?) -> Void) {
        encode(ProcessSnapshotPayload(timestamp: Date(), records: ProcessSampling.records()), reply: reply)
    }

    func collectInventory(pid: Int32, startTime: Double, reply: @escaping (Data?, String?) -> Void) {
        let payload = InventorySampling.collect(
            pid: pid,
            startTime: Date(timeIntervalSince1970: startTime)
        )
        encode(payload, reply: reply)
    }

    func captureFileActivity(pid: Int32, startTime: Double, reply: @escaping (Data?, String?) -> Void) {
        FileActivityCapture.start(pid: pid, startTime: startTime, reply: reply)
    }

    func collectNetworkPorts(reply: @escaping (Data?, String?) -> Void) {
        encode(ProcessSockets.collect(), reply: reply)
    }

    private func encode<T: Encodable>(_ value: T, reply: (Data?, String?) -> Void) {
        do {
            reply(try JSONEncoder().encode(value), nil)
        } catch {
            logger.error("Could not encode a privileged reply: \(error.localizedDescription, privacy: .public)")
            reply(nil, error.localizedDescription)
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Checked per connection, so users created or demoted after the admin approved the
        // helper are evaluated with their current group membership.
        let uid = newConnection.effectiveUserIdentifier
        guard ClientAuthorization.isAdministrator(uid: uid) else {
            logger.notice("Rejected a connection from non-administrator uid \(uid, privacy: .public)")
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: SmackPrivilegedSampling.self)
        let service = PrivilegedSamplingService()
        newConnection.exportedObject = service
        newConnection.invalidationHandler = { service.stopScan() }
        newConnection.resume()
        return true
    }
}

enum ClientAuthorization {
    private static let adminGroupID: gid_t = 80

    static func isAdministrator(uid: uid_t) -> Bool {
        guard let password = getpwuid(uid), let name = password.pointee.pw_name else { return false }
        let primaryGroup = password.pointee.pw_gid
        var count: Int32 = 256
        var groups = [Int32](repeating: 0, count: Int(count))
        guard getgrouplist(name, Int32(bitPattern: primaryGroup), &groups, &count) == 0 else { return false }
        return groups.prefix(Int(count)).contains(Int32(adminGroupID))
    }
}

// The app and helper must come from the same signer: Developer ID builds pin the Team ID,
// self-signed builds pin the leaf certificate, and ad-hoc builds are refused.
guard let requirement = SigningIdentity.current().requirement(forIdentifier: SmackIPC.appBundleIdentifier) else {
    logger.fault("The helper has no stable code signature; refusing to accept connections")
    exit(EXIT_FAILURE)
}
let listener = NSXPCListener(machServiceName: SmackIPC.machServiceName)
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.setConnectionCodeSigningRequirement(requirement)
listener.resume()
logger.notice("Privileged sampling helper started; client requirement: \(requirement, privacy: .public)")
RunLoop.current.run()
