import Darwin
import Foundation

/// Enumerates TCP sockets and their owning process. Used unprivileged by the app and as
/// root by the helper. It does not spawn `lsof` or any other external tool.
public enum ProcessSockets {
    private static let maximumDescriptors = 4_096

    public static func collect() -> SocketCollection {
        var records: [SocketRecord] = []
        var userNames: [uid_t: String] = [:]
        var denied = 0

        for pid in ProcessSampling.allProcessIdentifiers() {
            guard let owner = owner(for: pid, userNames: &userNames),
                  let connections = connections(for: pid) else {
                denied += 1
                continue
            }
            for connection in connections where connection.protocolName == "TCP" {
                records.append(SocketRecord(
                    owner: owner,
                    descriptor: connection.descriptor,
                    localAddress: connection.localAddress,
                    remoteAddress: connection.remoteAddress,
                    state: connection.state
                ))
            }
        }
        return SocketCollection(records: records, deniedProcessCount: denied)
    }

    private static func owner(for pid: pid_t, userNames: inout [uid_t: String]) -> SocketOwnerRecord? {
        var information = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, size) == size else { return nil }
        let name = string(from: information.pbi_name)
        let command = string(from: information.pbi_comm)
        let processName = !name.isEmpty ? name : (!command.isEmpty ? command : "Process \(pid)")
        return SocketOwnerRecord(
            pid: pid,
            name: processName,
            userName: userName(for: information.pbi_uid, cache: &userNames)
        )
    }

    private static func connections(for pid: pid_t) -> [ConnectionRecord]? {
        let descriptorSize = MemoryLayout<proc_fdinfo>.size
        let reportedBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard reportedBytes >= 0 else { return nil }
        guard reportedBytes > 0 else { return [] }

        let count = min(Int(reportedBytes) / descriptorSize, maximumDescriptors)
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let bufferSize = Int32(count * descriptorSize)
        let bytesRead = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, bufferSize)
        }
        guard bytesRead >= 0 else { return nil }

        var result: [ConnectionRecord] = []
        for descriptor in descriptors.prefix(Int(bytesRead) / descriptorSize)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var information = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &information, size) == size else {
                continue
            }
            if let connection = InventorySampling.connection(fd: descriptor.proc_fd, information: information.psi) {
                result.append(connection)
            }
        }
        return result
    }

    private static func userName(for uid: uid_t, cache: inout [uid_t: String]) -> String? {
        if let cached = cache[uid] { return cached }
        guard let password = getpwuid(uid), let name = password.pointee.pw_name else { return nil }
        guard let value = String(validatingCString: name) else { return nil }
        cache[uid] = value
        return value
    }

    private static func string<T>(from value: T) -> String {
        withUnsafeBytes(of: value) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
