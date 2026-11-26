import Darwin
import Foundation

/// Read-only process inventory built from libproc. The app uses it unprivileged; the root
/// helper uses the same code to inspect processes owned by other users. It never reads file
/// contents or process memory.
public enum InventorySampling {
    private struct Budget {
        let deadline = Date().addingTimeInterval(2)

        var canContinue: Bool {
            !Task.isCancelled && Date() < deadline
        }
    }

    private static let maximumDescriptors = 2_048
    private static let maximumThreads = 512
    private static let maximumRegions = 4_096

    public static func collect(pid: Int32, startTime: Date) -> InventoryPayload {
        var payload = InventoryPayload()
        var information = proc_taskallinfo()
        let informationSize = Int32(MemoryLayout<proc_taskallinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &information, informationSize) == informationSize else {
            payload.warnings.append("Process information is unavailable: \(errorDescription()).")
            return payload
        }
        let actualStart = Date(
            timeIntervalSince1970: Double(information.pbsd.pbi_start_tvsec)
                + Double(information.pbsd.pbi_start_tvusec) / 1_000_000
        )
        guard actualStart == startTime else {
            payload.warnings.append("The process exited and its PID may have been reused; inventory was not collected.")
            return payload
        }

        var budget = Budget()
        inspectDescriptors(pid: pid, budget: &budget, payload: &payload)
        inspectThreads(pid: pid, budget: &budget, payload: &payload)
        inspectMappedImages(pid: pid, budget: &budget, payload: &payload)

        if Task.isCancelled {
            payload.warnings.append("Inventory collection was cancelled; results may be incomplete.")
        } else if !budget.canContinue {
            payload.warnings.append("Inventory collection reached its time limit; results may be incomplete.")
        }
        return payload
    }

    private enum DescriptorResult<Value> {
        case item(Value)
        case empty
        case failed
    }

    private static func listProcessItems<Element>(
        pid: pid_t,
        flavor: Int32,
        maximumCount: Int,
        unavailablePrefix: String,
        truncationWarning: String,
        payload: inout InventoryPayload,
        makeDefault: () -> Element
    ) -> ArraySlice<Element>? {
        let elementSize = MemoryLayout<Element>.size
        let reportedBytes = proc_pidinfo(pid, flavor, 0, nil, 0)
        guard reportedBytes > 0 else {
            if reportedBytes < 0 {
                payload.warnings.append("\(unavailablePrefix): \(errorDescription()).")
            }
            return nil
        }

        let reportedCount = Int(reportedBytes) / elementSize
        let count = min(reportedCount, maximumCount)
        var items = (0..<count).map { _ in makeDefault() }
        let bufferSize = Int32(count * elementSize)
        let bytesRead = items.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, flavor, 0, buffer.baseAddress, bufferSize)
        }
        guard bytesRead >= 0 else {
            payload.warnings.append("\(unavailablePrefix): \(errorDescription()).")
            return nil
        }
        if reportedCount > maximumCount {
            payload.warnings.append(truncationWarning)
        }
        return items.prefix(Int(bytesRead) / elementSize)
    }

    private static func inspectDescriptors(pid: pid_t, budget: inout Budget, payload: inout InventoryPayload) {
        guard budget.canContinue,
              let descriptors = listProcessItems(
                  pid: pid,
                  flavor: PROC_PIDLISTFDS,
                  maximumCount: maximumDescriptors,
                  unavailablePrefix: "File and network inventory is unavailable",
                  truncationWarning: "Only the first \(maximumDescriptors) file descriptors were inspected.",
                  payload: &payload,
                  makeDefault: proc_fdinfo.init
              ) else { return }

        var fileFailures = 0
        var socketFailures = 0
        for descriptor in descriptors {
            guard budget.canContinue else { return }
            switch descriptor.proc_fdtype {
            case UInt32(PROX_FDTYPE_VNODE):
                switch inspectVnodeDescriptor(pid: pid, fd: descriptor.proc_fd) {
                case .item(let record): payload.files.append(record)
                case .empty: break
                case .failed: fileFailures += 1
                }
            case UInt32(PROX_FDTYPE_SOCKET):
                switch inspectSocketDescriptor(pid: pid, fd: descriptor.proc_fd) {
                case .item(let (connection, unixFile)):
                    payload.connections.append(connection)
                    if let unixFile { payload.files.append(unixFile) }
                case .empty: break
                case .failed: socketFailures += 1
                }
            default:
                continue
            }
        }
        if fileFailures > 0 {
            payload.warnings.append("\(fileFailures) file descriptor(s) could not be inspected; access may be restricted or they may have closed.")
        }
        if socketFailures > 0 {
            payload.warnings.append("\(socketFailures) socket descriptor(s) could not be inspected; access may be restricted or they may have closed.")
        }
    }

    private static func inspectVnodeDescriptor(pid: pid_t, fd: Int32) -> DescriptorResult<FileRecord> {
        var fileInformation = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &fileInformation, size) == size else {
            return .failed
        }
        let path = string(from: fileInformation.pvip.vip_path)
        return path.isEmpty ? .empty : .item(FileRecord(descriptor: fd, path: path, kind: "File"))
    }

    private static func inspectSocketDescriptor(pid: pid_t, fd: Int32) -> DescriptorResult<(ConnectionRecord, FileRecord?)> {
        var socketInformation = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &socketInformation, size) == size else {
            return .failed
        }
        guard let connection = connection(fd: fd, information: socketInformation.psi) else {
            return .empty
        }
        let unixFile = (connection.protocolName == "UNIX" && connection.localAddress != "—")
            ? FileRecord(descriptor: fd, path: connection.localAddress, kind: "Unix Socket")
            : nil
        return .item((connection, unixFile))
    }

    private static func inspectThreads(pid: pid_t, budget: inout Budget, payload: inout InventoryPayload) {
        guard budget.canContinue,
              let identifiers = listProcessItems(
                  pid: pid,
                  flavor: PROC_PIDLISTTHREADS,
                  maximumCount: maximumThreads,
                  unavailablePrefix: "Thread inventory is unavailable",
                  truncationWarning: "Only the first \(maximumThreads) threads were inspected.",
                  payload: &payload,
                  makeDefault: { UInt64(0) }
              ) else { return }

        var detailFailures = 0
        for identifier in identifiers {
            guard budget.canContinue else { return }
            var information = proc_threadinfo()
            let size = Int32(MemoryLayout<proc_threadinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTHREADID64INFO, identifier, &information, size) == size else {
                payload.threads.append(ThreadRecord(id: identifier, name: nil))
                detailFailures += 1
                continue
            }
            let name = string(from: information.pth_name)
            payload.threads.append(ThreadRecord(id: identifier, name: name.isEmpty ? nil : name))
        }
        if detailFailures > 0 {
            payload.warnings.append("Names are unavailable for \(detailFailures) thread(s).")
        }
    }

    private static func inspectMappedImages(pid: pid_t, budget: inout Budget, payload: inout InventoryPayload) {
        guard budget.canContinue else { return }
        var paths: Set<String> = []
        var address: UInt64 = 0
        var inspectedRegions = 0
        var failure: String?

        for _ in 0..<maximumRegions {
            guard budget.canContinue else { return }
            var information = proc_regionwithpathinfo()
            let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
            let result = proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &information, size)
            if result <= 0 {
                if inspectedRegions == 0 && result < 0 {
                    failure = errorDescription()
                }
                break
            }
            inspectedRegions += 1
            let path = string(from: information.prp_vip.vip_path)
            if !path.isEmpty {
                paths.insert(path)
            }
            let region = information.prp_prinfo
            guard region.pri_size > 0, region.pri_address <= UInt64.max - region.pri_size else { break }
            let nextAddress = region.pri_address + region.pri_size
            guard nextAddress > address else { break }
            address = nextAddress
        }

        if let failure {
            payload.warnings.append("Loaded-image inventory is unavailable: \(failure).")
            return
        }
        payload.libraries = paths.sorted().map(LibraryRecord.init(path:))
        if inspectedRegions == maximumRegions {
            payload.warnings.append("Loaded-image inspection stopped at \(maximumRegions) memory regions; results may be incomplete.")
        }
    }

    public static func connection(fd: Int32, information: socket_info) -> ConnectionRecord? {
        switch information.soi_kind {
        case Int32(SOCKINFO_TCP):
            let internet = information.soi_proto.pri_tcp.tcpsi_ini
            return internetConnection(
                fd: fd,
                information: information,
                internet: internet,
                protocolName: "TCP",
                state: tcpState(information.soi_proto.pri_tcp.tcpsi_state)
            )
        case Int32(SOCKINFO_IN):
            let internet = information.soi_proto.pri_in
            let protocolName = information.soi_protocol == IPPROTO_UDP ? "UDP" : "IP"
            let connected = information.soi_state & Int16(SOI_S_ISCONNECTED) != 0
            return internetConnection(
                fd: fd,
                information: information,
                internet: internet,
                protocolName: protocolName,
                state: connected ? "CONNECTED" : "UNCONNECTED"
            )
        case Int32(SOCKINFO_UN):
            let unix = information.soi_proto.pri_un
            let local = string(from: unix.unsi_addr.ua_sun.sun_path)
            let remote = string(from: unix.unsi_caddr.ua_sun.sun_path)
            let connected = information.soi_state & Int16(SOI_S_ISCONNECTED) != 0
            return ConnectionRecord(
                descriptor: fd,
                protocolName: "UNIX",
                localAddress: local.isEmpty ? "—" : local,
                remoteAddress: remote.isEmpty ? "—" : remote,
                state: connected ? "CONNECTED" : "UNCONNECTED"
            )
        default:
            return nil
        }
    }

    private static func internetConnection(
        fd: Int32,
        information: socket_info,
        internet: in_sockinfo,
        protocolName: String,
        state: String
    ) -> ConnectionRecord {
        let isIPv6 = internet.insi_vflag & UInt8(INI_IPV6) != 0
        let localBytes = addressBytes(from: internet.insi_laddr, isIPv6: isIPv6)
        let remoteBytes = addressBytes(from: internet.insi_faddr, isIPv6: isIPv6)
        let family = isIPv6 ? AF_INET6 : AF_INET
        let localPort = UInt16(truncatingIfNeeded: internet.insi_lport)
        let remotePort = UInt16(truncatingIfNeeded: internet.insi_fport)
        let local = socketEndpoint(addressBytes: localBytes, networkPort: localPort, family: family)
        let remoteIsEmpty = remoteBytes.allSatisfy { $0 == 0 } && UInt16(bigEndian: remotePort) == 0
        return ConnectionRecord(
            descriptor: fd,
            protocolName: protocolName,
            localAddress: local,
            remoteAddress: remoteIsEmpty ? "—" : socketEndpoint(addressBytes: remoteBytes, networkPort: remotePort, family: family),
            state: state
        )
    }

    private static func addressBytes<T>(from address: T, isIPv6: Bool) -> [UInt8] {
        withUnsafeBytes(of: address) { bytes in
            if isIPv6 {
                return Array(bytes.prefix(16))
            }
            guard bytes.count >= 16 else { return [] }
            return Array(bytes[12..<16])
        }
    }

    public static func socketEndpoint(addressBytes: [UInt8], networkPort: UInt16, family: Int32) -> String {
        let expectedLength = family == AF_INET6 ? 16 : 4
        guard addressBytes.count == expectedLength else { return "—" }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let result = addressBytes.withUnsafeBufferPointer { address in
            inet_ntop(family, address.baseAddress, &buffer, socklen_t(buffer.count))
        }
        guard result != nil else { return "—" }
        let address = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let port = UInt16(bigEndian: networkPort)
        return family == AF_INET6 ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    public static func tcpState(_ state: Int32) -> String {
        switch state {
        case TSI_S_CLOSED: return "CLOSED"
        case TSI_S_LISTEN: return "LISTEN"
        case TSI_S_SYN_SENT: return "SYN_SENT"
        case TSI_S_SYN_RECEIVED: return "SYN_RECEIVED"
        case TSI_S_ESTABLISHED: return "ESTABLISHED"
        case TSI_S__CLOSE_WAIT: return "CLOSE_WAIT"
        case TSI_S_FIN_WAIT_1: return "FIN_WAIT_1"
        case TSI_S_CLOSING: return "CLOSING"
        case TSI_S_LAST_ACK: return "LAST_ACK"
        case TSI_S_FIN_WAIT_2: return "FIN_WAIT_2"
        case TSI_S_TIME_WAIT: return "TIME_WAIT"
        default: return "UNKNOWN (\(state))"
        }
    }

    private static func string<T>(from value: T) -> String {
        withUnsafeBytes(of: value) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func errorDescription(_ error: Int32 = errno) -> String {
        String(validatingCString: strerror(error)) ?? "Unknown error"
    }
}
