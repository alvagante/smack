import Foundation
import Testing
import Darwin
@testable import Smack

// Explicit opt-in: timings are evidence, not portable CI assertions.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SMACK_PHASE0_BENCHMARK"] == "1"))
func phase0AlertBenchmark() async throws {
    func report(_ name: String, _ values: [Double], _ fired: Int, _ initialRSS: Int64, _ finalRSS: Int64) {
        let sorted = values.sorted()
        let result: [String: Any] = ["workload": name, "iterations": values.count,
            "mean_ms": values.reduce(0, +) / Double(values.count), "p50_ms": sorted[sorted.count / 2],
            "p95_ms": sorted[Int(Double(sorted.count - 1) * 0.95)], "max_ms": sorted.last!, "fired": fired, "maxrss_start_bytes": initialRSS, "maxrss_end_bytes": finalRSS]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("PHASE0 " + String(data: data, encoding: .utf8)!)
    }
    for workload in ["system-50-armed", "system-50-pending", "process-1-any-1000", "process-10-any-1000", "process-50-exact-1000", "process-50-any-1000",
                     "process-50-any-1000-churn"] {
        let engine = AlertEngine()
        let system = workload.hasPrefix("system")
        let any = workload.contains("any")
        let pending = workload.contains("pending")
        // Churn: values move every sample, a tenth of the processes exit, and rules fire and clear.
        let churn = workload.hasSuffix("churn")
        let ruleCount = workload.contains("process-1-") ? 1 : workload.contains("process-10-") ? 10 : 50
        let rules = (0..<ruleCount).map { i in
            if system {
                return AlertRule(name: "CPU \(i)", enabled: true, kind: .systemThreshold(metric: .cpuTotal,
                    comparison: .greaterThan, value: pending ? 0 : 90, sustain: 100_000, clear: nil))
            }
            return AlertRule(name: "Process \(i)", enabled: true, kind: .processThreshold(metric: .cpu,
                matcher: ProcessMatcher(name: any ? nil : "p\(i + 1)", anyProcess: any),
                comparison: .greaterThan, value: churn ? 70 + Double(i % 20) : 90, sustain: churn ? 2 : 100_000, clear: churn ? 2 : nil))
        }
        await engine.update(rules: rules)
        let processes = (1...1000).map { obsProcess(Int32($0), cpu: Double($0 % 80)) }
        var initial = rusage(); getrusage(RUSAGE_SELF, &initial)
        var values: [Double] = []
        var fired = 0
        for i in 0..<(system ? 1010 : 110) {
            let time = 1000 + Double(i)
            let sample = obsSystem(at: time)
            var current = processes
            if churn {
                current = []
                for pid in 1...1000 where pid % 10 != i % 10 {
                    let cpu = Double((pid * 7 + i * 13) % 100)
                    current.append(obsProcess(Int32(pid), cpu: cpu))
                }
            }
            let snapshot = obsSnapshot(current, at: time)
            let start = DispatchTime.now().uptimeNanoseconds
            let alerts = system
                ? await engine.evaluate(system: sample, expectedInterval: 1)
                : await engine.evaluate(processes: snapshot, expectedInterval: 1)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            if i >= 10 { values.append(elapsed); fired += alerts.count }
        }
        var final = rusage(); getrusage(RUSAGE_SELF, &final)
        report(workload, values, fired, Int64(initial.ru_maxrss), Int64(final.ru_maxrss))
    }
}
