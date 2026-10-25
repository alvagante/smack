import Darwin
import Foundation

final class InventoryCollector: InventoryCollecting {
    private struct Budget {
        let deadline = Date().addingTimeInterval(2)

        var canContinue: Bool {
            !Task.isCancelled && Date() < deadline
        }
    }

    private static let maximumDescriptors = 2_048
    private static let maximumThreads = 512
    private static let maximumRegions = 4_096

    init() {}

    func collectInventory(for process: ProcessMetrics) -> ProcessInventory {
        var inventory = ProcessInventory()
        let pid = process.identity.pid
        var information = proc_taskallinfo()
        let informationSize = Int32(MemoryLayout<proc_taskallinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &information, informationSize) == informationSize else {
            inventory.warnings.append("Process information is unavailable: \(Self.errorDescription()).")
            return inventory
        }
        let startTime = Date(
            timeIntervalSince1970: Double(information.pbsd.pbi_start_tvsec)
                + Double(information.pbsd.pbi_start_tvusec) / 1_000_000
        )
        guard startTime == process.identity.startTime else {
            inventory.warnings.append("The process exited and its PID may have been reused; inventory was not collected.")
            return inventory
        }

        var budget = Budget()
        inspectDescriptors(pid: pid, budget: &budget, inventory: &inventory)
        inspectThreads(pid: pid, budget: &budget, inventory: &inventory)
        inspectMappedImages(pid: pid, budget: &budget, inventory: &inventory)

        if Task.isCancelled {
            inventory.warnings.append("Inventory collection was cancelled; results may be incomplete.")
        } else if !budget.canContinue {
            inventory.warnings.append("Inventory collection reached its time limit; results may be incomplete.")
        }
        return inventory
    }

    private func inspectDescriptors(pid: pid_t, budget: inout Budget, inventory: inout ProcessInventory) {
        guard budget.canContinue else { return }
        let descriptorSize = MemoryLayout<proc_fdinfo>.size
        let reportedBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard reportedBytes > 0 else {
            if reportedBytes < 0 {
                inventory.warnings.append("File and network inventory is unavailable: \(Self.errorDescription()).")
            }
            return
        }

        let reportedCount = Int(reportedBytes) / descriptorSize
        let count = min(reportedCount, Self.maximumDescriptors)
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let bufferSize = Int32(count * descriptorSize)
        let bytesRead = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, bufferSize)
        }
        guard bytesRead >= 0 else {
            inventory.warnings.append("File and network inventory is unavailable: \(Self.errorDescription()).")
            return
        }
        if reportedCount > Self.maximumDescriptors {
            inventory.warnings.append("Only the first \(Self.maximumDescriptors) file descriptors were inspected.")
        }

        var fileFailures = 0
        var socketFailures = 0
        for descriptor in descriptors.prefix(Int(bytesRead) / descriptorSize) {
            guard budget.canContinue else { return }
            switch descriptor.proc_fdtype {
            case UInt32(PROX_FDTYPE_VNODE):
                var fileInformation = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &fileInformation, size) == size else {
                    fileFailures += 1
                    continue
                }
                let path = Self.string(from: fileInformation.pvip.vip_path)
                if !path.isEmpty {
                    inventory.files.append(OpenFile(id: descriptor.proc_fd, path: path, descriptorType: "File"))
                }
            case UInt32(PROX_FDTYPE_SOCKET):
                var socketInformation = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socketInformation, size) == size else {
                    socketFailures += 1
                    continue
                }
                if let connection = Self.connection(fd: descriptor.proc_fd, information: socketInformation.psi) {
                    inventory.connections.append(connection)
                    if connection.protocolName == "UNIX", connection.localAddress != "—" {
                        inventory.files.append(OpenFile(
                            id: descriptor.proc_fd,
                            path: connection.localAddress,
                            descriptorType: "Unix Socket"
                        ))
                    }
                }
            default:
                continue
            }
        }
        if fileFailures > 0 {
            inventory.warnings.append("\(fileFailures) file descriptor(s) could not be inspected; access may be restricted or they may have closed.")
        }
        if socketFailures > 0 {
            inventory.warnings.append("\(socketFailures) socket descriptor(s) could not be inspected; access may be restricted or they may have closed.")
        }
    }

    private func inspectThreads(pid: pid_t, budget: inout Budget, inventory: inout ProcessInventory) {
        guard budget.canContinue else { return }
        let identifierSize = MemoryLayout<UInt64>.size
        let reportedBytes = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, nil, 0)
        guard reportedBytes > 0 else {
            if reportedBytes < 0 {
                inventory.warnings.append("Thread inventory is unavailable: \(Self.errorDescription()).")
            }
            return
        }

        let reportedCount = Int(reportedBytes) / identifierSize
        let count = min(reportedCount, Self.maximumThreads)
        var identifiers = [UInt64](repeating: 0, count: count)
        let bufferSize = Int32(count * identifierSize)
        let bytesRead = identifiers.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, buffer.baseAddress, bufferSize)
        }
        guard bytesRead >= 0 else {
            inventory.warnings.append("Thread inventory is unavailable: \(Self.errorDescription()).")
            return
        }
        if reportedCount > Self.maximumThreads {
            inventory.warnings.append("Only the first \(Self.maximumThreads) threads were inspected.")
        }

        var detailFailures = 0
        for identifier in identifiers.prefix(Int(bytesRead) / identifierSize) {
            guard budget.canContinue else { return }
            var information = proc_threadinfo()
            let size = Int32(MemoryLayout<proc_threadinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTHREADID64INFO, identifier, &information, size) == size else {
                inventory.threads.append(ThreadInfo(id: identifier, name: nil))
                detailFailures += 1
                continue
            }
            let name = Self.string(from: information.pth_name)
            inventory.threads.append(ThreadInfo(id: identifier, name: name.isEmpty ? nil : name))
        }
        if detailFailures > 0 {
            inventory.warnings.append("Names are unavailable for \(detailFailures) thread(s).")
        }
    }

    private func inspectMappedImages(pid: pid_t, budget: inout Budget, inventory: inout ProcessInventory) {
        guard budget.canContinue else { return }
        var paths: Set<String> = []
        var address: UInt64 = 0
        var inspectedRegions = 0
        var failure: String?

        for _ in 0..<Self.maximumRegions {
            guard budget.canContinue else { return }
            var information = proc_regionwithpathinfo()
            let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
            let result = proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &information, size)
            if result <= 0 {
                if inspectedRegions == 0 && result < 0 {
                    failure = Self.errorDescription()
                }
                break
            }
            inspectedRegions += 1
            let path = Self.string(from: information.prp_vip.vip_path)
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
            inventory.warnings.append("Loaded-image inventory is unavailable: \(failure).")
            return
        }
        inventory.libraries = paths.sorted().map(LoadedLibrary.init(path:))
        if inspectedRegions == Self.maximumRegions {
            inventory.warnings.append("Loaded-image inspection stopped at \(Self.maximumRegions) memory regions; results may be incomplete.")
        }
    }

    private static func connection(fd: Int32, information: socket_info) -> NetworkConnection? {
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
            let local = Self.string(from: unix.unsi_addr.ua_sun.sun_path)
            let remote = Self.string(from: unix.unsi_caddr.ua_sun.sun_path)
            let connected = information.soi_state & Int16(SOI_S_ISCONNECTED) != 0
            return NetworkConnection(
                id: fd,
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
    ) -> NetworkConnection {
        let isIPv6 = internet.insi_vflag & UInt8(INI_IPV6) != 0
        let localBytes = Self.addressBytes(from: internet.insi_laddr, isIPv6: isIPv6)
        let remoteBytes = Self.addressBytes(from: internet.insi_faddr, isIPv6: isIPv6)
        let family = isIPv6 ? AF_INET6 : AF_INET
        let localPort = UInt16(truncatingIfNeeded: internet.insi_lport)
        let remotePort = UInt16(truncatingIfNeeded: internet.insi_fport)
        let local = socketEndpoint(addressBytes: localBytes, networkPort: localPort, family: family)
        let remoteIsEmpty = remoteBytes.allSatisfy { $0 == 0 } && UInt16(bigEndian: remotePort) == 0
        return NetworkConnection(
            id: fd,
            protocolName: protocolName,
            localAddress: local,
            remoteAddress: remoteIsEmpty ? "—" : socketEndpoint(addressBytes: remoteBytes, networkPort: remotePort, family: family),
            state: state
        )
    }

    private static func addressBytes<T>(from address: T, isIPv6: Bool) -> [UInt8] {
        withUnsafeBytes(of: address) { bytes in
            Array(isIPv6 ? bytes.prefix(16) : bytes.prefix(4))
        }
    }

    static func socketEndpoint(addressBytes: [UInt8], networkPort: UInt16, family: Int32) -> String {
        let expectedLength = family == AF_INET6 ? 16 : 4
        guard addressBytes.count == expectedLength else { return "—" }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let result = addressBytes.withUnsafeBufferPointer { address in
            inet_ntop(family, address.baseAddress, &buffer, socklen_t(buffer.count))
        }
        guard result != nil else { return "—" }
        let address = String(cString: buffer)
        let port = UInt16(bigEndian: networkPort)
        return family == AF_INET6 ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    static func tcpState(_ state: Int32) -> String {
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
        String(cString: strerror(error))
    }
}
