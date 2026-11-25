import Foundation
import Testing
@testable import Smack

@Suite struct LiveMetricsTests {
    @Test func processPointsStayBoundedAndForgetExitedProcesses() throws {
        var metrics = LiveMetrics(capacity: 3)

        for tick in 0..<5 {
            metrics.receive(obsSnapshot([obsProcess(10, cpu: Double(tick)), obsProcess(11)], at: 1_000 + Double(tick)))
        }

        let kept = try #require(metrics.processPoints[obsProcess(10).id])
        #expect(kept.map(\.cpuUsage) == [2, 3, 4])

        metrics.receive(obsSnapshot([obsProcess(10)], at: 2_000))
        #expect(metrics.processPoints[obsProcess(11).id] == nil)
    }

    @Test func systemSamplesUpdateAggregateAndGPUHistory() {
        var metrics = LiveMetrics()
        let process = obsProcess(60)
        metrics.receive(obsSnapshot([process], at: 1_000))
        var sample = obsSystem(at: 1_001)
        sample.gpuProcesses = [60: 30]

        metrics.receive(sample, processes: obsSnapshot([process], at: 1_000))

        #expect(metrics.system.points.last?.timestamp == sample.timestamp)
        #expect(metrics.currentGPUUsage(process.id) == 30)

        metrics.receive(obsSystem(at: 1_002), processes: obsSnapshot([process], at: 1_000))
        #expect(metrics.gpuPoints.isEmpty)
    }
}
