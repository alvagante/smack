import Foundation
import SmackIPC
import Synchronization

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
    static func stream(interval: TimeInterval,
                       receive: @escaping @Sendable (ProcessNetworkSample?) async -> Void) async {
        guard !Capabilities.isSandboxed else { return }
        let parser = Mutex(ProcessNetworkStreamParser())
        let (samples, continuation) = AsyncStream<ProcessNetworkSample?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                defer { continuation.finish() }
                // nettop ignores write errors and macOS has no parent-death signal, so an abrupt Smack exit would
                // orphan it forever. The watcher gets EOF on held stdin when Smack dies and kills nettop, which
                // exec keeps as the spawned PID for signals and exit status.
                let nettop = "/usr/bin/nettop -P -L 0 -d -s \(Int(interval.rounded(.up))) -n -x -J bytes_in,bytes_out"
                let result = await Subprocess.run(
                    "/bin/sh", ["-c", "(cat >/dev/null; kill $$) <&0 >/dev/null 2>&1 & exec \(nettop) </dev/null"],
                    outputLimit: 16 * 1_024,
                    processGroup: BaselineWorker.isRunning ? .inherited : .new,
                    terminalOutput: true, outputTimeout: max(10, interval * 3), holdInput: true,
                    onOutput: { event in
                        parser.withLock { parser in
                            for sample in parser.consume(event) { continuation.yield(sample) }
                        }
                    }
                )
                if !result.cancelled { continuation.yield(nil) }
            }
            for await sample in samples {
                guard !Task.isCancelled else { break }
                await receive(sample)
            }
            group.cancelAll()
        }
    }
}

/// nettop has no end-of-block delimiter. A short stdout idle period completes a burst;
/// the next header also completes it if the whole burst arrived in a single read.
struct ProcessNetworkStreamParser: Sendable {
    private var pending = Data()
    private var blockBytes = 0
    private var oversizedLine = false
    private let limit = 4 * 1_024 * 1_024
    private var previousHeader: (uptime: TimeInterval, date: Date)?
    private var startedAt: Date?
    private var duration: TimeInterval = 0
    private var receiveIndex: Int?
    private var sendIndex: Int?
    private var headerCount = 0
    private var valid = false
    private var published = true
    private var rates: [Int32: ProcessNetworkThroughput] = [:]

    mutating func consume(_ event: Subprocess.OutputEvent,
                          uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                          date: Date = Date()) -> [ProcessNetworkSample?] {
        var samples: [ProcessNetworkSample?] = []
        switch event {
        case .data(let data):
            for byte in data {
                if byte == 10 {
                    let line = String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .newlines)
                    pending.removeAll(keepingCapacity: true)
                    if oversizedLine { oversizedLine = false; continue }
                    let columns = line.split(separator: ",", omittingEmptySubsequences: false)
                    if columns.first == "", line.hasPrefix(",") {
                        finish(into: &samples)
                        startedAt = previousHeader?.date
                        duration = previousHeader.map { uptime - $0.uptime } ?? 0
                        previousHeader = (uptime, date)
                        receiveIndex = columns.firstIndex(of: "bytes_in")
                        sendIndex = columns.firstIndex(of: "bytes_out")
                        headerCount = columns.count
                        valid = receiveIndex != nil && sendIndex != nil && duration > 0
                        published = false
                        blockBytes = 0
                        rates.removeAll(keepingCapacity: true)
                    } else if !published && valid, let receiveIndex, let sendIndex {
                        let extra = columns.count - headerCount
                        guard extra >= 0 else { valid = false; continue }
                        let label = columns.prefix(extra + 1).joined(separator: ",").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        guard let suffix = label.split(separator: ".").last,
                              let pid = Int32(suffix), pid > 0,
                              let received = UInt64(columns[receiveIndex + extra]),
                              let sent = UInt64(columns[sendIndex + extra]) else { valid = false; continue }
                        rates[pid] = ProcessNetworkThroughput(receiveRate: Double(received) / duration,
                                                              sendRate: Double(sent) / duration)
                    }
                } else {
                    blockBytes = min(blockBytes + 1, limit + 1)
                    if blockBytes > limit { valid = false }
                    if !oversizedLine {
                        if pending.count < limit { pending.append(byte) }
                        else { oversizedLine = true; pending.removeAll(keepingCapacity: true) }
                    }
                }
            }
        case .idle:
            // A split line is not a complete block, even if the writer temporarily stalls.
            if pending.isEmpty && !oversizedLine { finish(into: &samples) }
        }
        return samples
    }

    private mutating func finish(into samples: inout [ProcessNetworkSample?]) {
        guard !published else { return }
        published = true
        if let startedAt {
            samples.append(valid ? ProcessNetworkSample(startedAt: startedAt, rates: rates) : nil)
        }
    }
}

/// One panel-owned sampling loop, independent of process/history collection cadence. It runs only while the panel
/// is visible and an interval is set; a nil interval turns per-process rates off.
actor ProcessNetworkSampler {
    typealias Stream = @Sendable (TimeInterval, @escaping @Sendable (ProcessNetworkSample?) async -> Void) async -> Void
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void
    private let stream: Stream
    private let now: @Sendable () -> TimeInterval
    private let sleep: Sleep
    private var interval: TimeInterval?
    /// A sample older than this many intervals is dropped instead of shown as current.
    private let ageFactor: Double
    private var maximumAge: TimeInterval { (interval ?? 0) * ageFactor }
    private var task: Task<Void, Never>?
    private var visible = false
    private var generation = 0
    private var sample: ProcessNetworkSample?
    private var receivedAt: TimeInterval?

    init(interval: TimeInterval = 5, maximumAge: TimeInterval = 10,
         stream: @escaping Stream = { await ProcessNetworkCollector.stream(interval: $0, receive: $1) },
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) }) {
        self.interval = interval
        self.ageFactor = maximumAge / max(interval, 0.001)
        self.stream = stream
        self.now = now
        self.sleep = sleep
    }

    deinit { task?.cancel() }

    func setVisible(_ value: Bool) async {
        guard value != visible else { return }
        visible = value
        await restart()
    }

    /// Changing the interval while visible restarts the loop at the new cadence; nil stops it.
    func setInterval(_ value: TimeInterval?) async {
        guard value != interval else { return }
        interval = value
        await restart()
    }

    private func restart() async {
        generation += 1
        let generation = generation
        let previous = task
        previous?.cancel()
        sample = nil
        receivedAt = nil
        // Reopening waits for the old subprocess to stop, so rapid toggles cannot overlap probes.
        await previous?.value
        guard self.generation == generation else { return }
        task = nil
        guard visible, let interval else { return }
        let stream = stream, sleep = sleep
        task = Task { [weak self] in
            while !Task.isCancelled {
                await stream(interval) { [weak self] value in
                    _ = await self?.receive(value, generation: generation)
                }
                guard !Task.isCancelled,
                      await self?.receive(nil, generation: generation) == true else { return }
                do { try await sleep(interval) }
                catch { return }
            }
        }
    }

    private func receive(_ value: ProcessNetworkSample?, generation: Int) -> Bool {
        guard self.generation == generation, visible else { return false }
        sample = value
        receivedAt = value == nil ? nil : now()
        return true
    }

    func latest() -> ProcessNetworkSample? {
        guard visible, let receivedAt, now() - receivedAt <= maximumAge else { return nil }
        return sample
    }
}
