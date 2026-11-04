import Darwin
import Foundation
import Testing
import SmackIPC

@Suite struct InventorySamplingTests {
    /// Regression: threads were never listed, because PROC_PIDLISTTHREADS reports no size for a nil buffer.
    @Test func listsNamedThreadsOfThisProcess() throws {
        let pid = getpid()
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        try #require(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size)
        let start = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)

        let name = "smack-inventory-test"
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let thread = Thread {
            started.signal()
            release.wait()
        }
        thread.name = name
        thread.start()
        started.wait()
        defer { release.signal() }

        let payload = InventorySampling.collect(pid: pid, startTime: start)
        #expect(payload.threads.count > 1)
        #expect(payload.threads.contains { $0.name == name })
        #expect(!payload.warnings.contains { $0.contains("Names are unavailable") })
        // The test thread runs this collection, so at least one thread is on a core and has used CPU.
        #expect(payload.threads.allSatisfy { $0.runState != nil && $0.userTime != nil && $0.priority != nil })
        #expect(payload.threads.contains { $0.runState == 1 })
    }
}
