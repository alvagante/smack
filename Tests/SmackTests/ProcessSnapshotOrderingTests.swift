import Foundation
import SmackIPC
import Testing
@testable import Smack

private actor DelayedSampler: PrivilegedSamplingProviding {
    private var requests: [Int: CheckedContinuation<ProcessSnapshotPayload?, Never>] = [:]
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    nonisolated func setAvailable(_ value: Bool) {}
    func collectInventory(pid: Int32, startTime: Date) async -> InventoryPayload? { nil }
    func captureFileActivity(pid: Int32, startTime: Date) async -> FileActivityPayload? { nil }

    func collectNetworkPorts() async -> SocketCollection? { nil }

    func collectSnapshot() async -> ProcessSnapshotPayload? {
        await withCheckedContinuation { continuation in
            requests[count] = continuation
            count += 1
            let ready = waiters.filter { $0.0 <= count }
            waiters.removeAll { $0.0 <= count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForRequests(_ target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }

    func reply(_ index: Int, _ payload: ProcessSnapshotPayload?) {
        requests.removeValue(forKey: index)?.resume(returning: payload)
    }
}

private final class UnusedLocalCollector: ProcessMetricsCollecting {
    func collectProcessSnapshot(includePrivileged: Bool) async -> ProcessSnapshot? { nil }
}

private func payload(_ timestamp: Double, cpu: UInt64, bytes: UInt64) -> ProcessSnapshotPayload {
    ProcessSnapshotPayload(timestamp: Date(timeIntervalSince1970: timestamp), records: [
        ProcessRecord(pid: 5_000_001, parentPID: 1, startTime: Date(timeIntervalSince1970: 1),
                      userID: 501, name: "ordered", executablePath: nil,
                      cpuTimeNanoseconds: cpu, physicalFootprint: 1024,
                      bytesRead: bytes, bytesWritten: bytes, energyNanojoules: cpu, threadCount: 1)
    ])
}

@Test func delayedAndDuplicateRepliesDoNotRewindRateCounters() async throws {
    let provider = DelayedSampler()
    let service = ProcessSnapshotService(local: UnusedLocalCollector(), privileged: provider)
    let old = Task { await service.collectProcessSnapshot(includePrivileged: true) }
    await provider.waitForRequests(1)
    let newer = Task { await service.collectProcessSnapshot(includePrivileged: true) }
    await provider.waitForRequests(2)
    await provider.reply(1, payload(20, cpu: 2_000_000_000, bytes: 200))
    #expect(await newer.value?.timestamp == Date(timeIntervalSince1970: 20))
    await provider.reply(0, payload(10, cpu: 0, bytes: 0))
    #expect(await old.value == nil)

    let duplicate = Task { await service.collectProcessSnapshot(includePrivileged: true) }
    await provider.waitForRequests(3)
    await provider.reply(2, payload(20, cpu: 99_000_000_000, bytes: 9999))
    #expect(await duplicate.value == nil)

    let next = Task { await service.collectProcessSnapshot(includePrivileged: true) }
    await provider.waitForRequests(4)
    await provider.reply(3, payload(30, cpu: 3_000_000_000, bytes: 300))
    let result = try #require(await next.value?.backgroundProcesses.first)
    #expect(result.cpuUsage == 10)
    #expect(result.diskReadRate == 10)
    #expect(result.diskWriteRate == 10)
}

@Test func cancelledReplyDoesNotAdvanceTimestampOrRateCounters() async throws {
    let provider = DelayedSampler()
    let service = ProcessSnapshotService(local: UnusedLocalCollector(), privileged: provider)
    let baseline = Task { await service.collectProcessSnapshot(includePrivileged: true) }
    await provider.waitForRequests(1)
    await provider.reply(0, payload(10, cpu: 1_000_000_000, bytes: 100))
    #expect(await baseline.value != nil)

    let cancelled = Task { await service.collectProcessSnapshot(includePrivileged: true) }
    await provider.waitForRequests(2)
    cancelled.cancel()
    await provider.reply(1, payload(100, cpu: 99_000_000_000, bytes: 9999))
    #expect(await cancelled.value == nil)

    let next = Task { await service.collectProcessSnapshot(includePrivileged: true) }
    await provider.waitForRequests(3)
    await provider.reply(2, payload(20, cpu: 2_000_000_000, bytes: 200))
    let result = try #require(await next.value?.backgroundProcesses.first)
    #expect(result.cpuUsage == 10)
    #expect(result.diskReadRate == 10)
}

private final class FixedLocalCollector: ProcessMetricsCollecting {
    func collectProcessSnapshot(includePrivileged: Bool) async -> ProcessSnapshot? {
        ProcessSnapshot(timestamp: Date(timeIntervalSince1970: 30), applications: [], backgroundProcesses: [])
    }
}

@Test func latePrivilegedReplyCannotReplaceNewerLocalFallback() async {
    let provider = DelayedSampler()
    let service = ProcessSnapshotService(local: FixedLocalCollector(), privileged: provider)
    let old = Task { await service.collectProcessSnapshot(includePrivileged: true) }
    await provider.waitForRequests(1)
    let fallback = Task { await service.collectProcessSnapshot(includePrivileged: true) }
    await provider.waitForRequests(2)
    await provider.reply(1, nil)
    #expect(await fallback.value?.timestamp == Date(timeIntervalSince1970: 30))
    await provider.reply(0, payload(20, cpu: 2_000_000_000, bytes: 200))
    #expect(await old.value == nil)
}
