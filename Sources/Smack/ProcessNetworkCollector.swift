import Foundation

struct ProcessNetworkThroughput: Sendable, Equatable {
    var receiveRate: Double
    var sendRate: Double
    var total: Double { receiveRate + sendRate }
    var formatted: String { "↓ \(Formatting.rate(receiveRate))  ↑ \(Formatting.rate(sendRate))" }
}

struct ProcessNetworkSample: Sendable {
    var startedAt: Date
    var rates: [Int32: ProcessNetworkThroughput]

    func throughput(for identity: ProcessIdentity) -> ProcessNetworkThroughput? {
        // A PID born during collection may have belonged to a different process in nettop's first sample.
        guard identity.startTime <= startedAt else { return nil }
        return rates[identity.pid]
    }
}

enum ProcessNetworkCollector {
    static func collect() async -> ProcessNetworkSample? {
        guard !Capabilities.isSandboxed else { return nil }
        let startedAt = Date()
        let result = await CommandRunner.run(
            "/usr/bin/nettop", ["-P", "-L", "2", "-d", "-s", "1", "-n", "-x", "-J", "bytes_in,bytes_out"],
            timeout: 4, outputLimit: 4 * 1_024 * 1_024
        )
        guard result.status == 0, !result.timedOut, !result.truncated, !result.cancelled,
              let rates = parse(result.output) else { return nil }
        return ProcessNetworkSample(startedAt: startedAt, rates: rates)
    }

    static func parse(_ output: String) -> [Int32: ProcessNetworkThroughput]? {
        var headers = 0
        var receiveIndex: Int?
        var sendIndex: Int?
        var headerCount = 0
        var rates: [Int32: ProcessNetworkThroughput] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            if columns.first == "" {
                headers += 1
                headerCount = columns.count
                receiveIndex = columns.firstIndex(of: "bytes_in")
                sendIndex = columns.firstIndex(of: "bytes_out")
                rates = [:]
                continue
            }
            // The first block is cumulative. Only the second block contains one-second deltas.
            guard headers == 2, let receiveIndex, let sendIndex else { continue }
            let extraColumns = columns.count - headerCount
            guard extraColumns >= 0 else { return nil }
            let label = columns.prefix(extraColumns + 1).joined(separator: ",").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard let suffix = label.split(separator: ".").last,
                  let pid = Int32(suffix), pid > 0,
                  let received = UInt64(columns[receiveIndex + extraColumns]),
                  let sent = UInt64(columns[sendIndex + extraColumns]) else { return nil }
            rates[pid] = ProcessNetworkThroughput(receiveRate: Double(received), sendRate: Double(sent))
        }
        guard headers == 2, receiveIndex != nil, sendIndex != nil else { return nil }
        return rates
    }
}
