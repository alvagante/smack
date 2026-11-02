import Foundation
import SmackIPC
import Synchronization
import Testing
@testable import Smack

struct CommandRunnerTests {
    @Test func capsAndDrainsBothOutputStreams() async {
        let result = await CommandRunner.run("/bin/sh", ["-c",
            "i=0; while [ $i -lt 10000 ]; do printf 'stdout'; printf 'stderr' >&2; i=$((i+1)); done"],
            timeout: 10, outputLimit: 1024)
        #expect(result.status == 0)
        #expect(!result.timedOut)
        #expect(result.output.utf8.count == 1024)
        #expect(result.error.utf8.count == 1024)
        #expect(result.truncated)
    }

    @Test func stderrAloneMarksTruncation() async {
        let result = await CommandRunner.run("/bin/sh", ["-c", "printf 'diagnostic' >&2"],
                                             timeout: 5, outputLimit: 4)
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
        #expect(result.error == "diag")
        #expect(result.truncated)
    }
    // Leave CI scheduling headroom while still failing if a child runs to completion.
    @Test func timeoutEscalatesForSIGTERMIgnoringProcess() async {
        let start = ContinuousClock.now
        let result = await CommandRunner.run("/bin/sh", ["-c", "trap '' TERM; sleep 30"], timeout: 0.1)
        #expect(result.timedOut)
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func inheritedPipesCannotDefeatTimeout() async {
        let start = ContinuousClock.now
        let result = await CommandRunner.run("/bin/sh", ["-c", "(trap '' TERM; sleep 30) & exit 0"], timeout: 0.1)
        #expect(result.timedOut)
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func cancellationInterruptsBlockedInputAndOutput() async {
        let start = ContinuousClock.now
        let task = Task {
            await CommandRunner.run("/bin/sh", ["-c", "trap '' TERM; sleep 30"],
                                    input: String(repeating: "x", count: 1_000_000))
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.value
        #expect(result.cancelled)
        #expect(!result.timedOut)
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func mutationCompletesDespiteCallerCancellation() async {
        let task = Task {
            await CommandRunner.run("/bin/sh", ["-c", "sleep 0.2; printf completed"], cancellable: false)
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.value
        #expect(result.status == 0)
        #expect(result.output == "completed")
        #expect(!result.cancelled)
    }

    @Test func inputIsDeliveredAndExitStatusPreserved() async {
        let result = await CommandRunner.run("/bin/sh", ["-c", "cat; exit 7"], input: "payload", timeout: 2)
        #expect(result.output == "payload")
        #expect(result.status == 7)
    }

    @Test func cancellationBeforeLaunchDoesNotRunCommand() async {
        let (gate, release) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in gate { break }
            return await CommandRunner.run("/bin/sh", ["-c", "printf launched"])
        }
        task.cancel()
        release.finish()
        let result = await task.value
        #expect(result.cancelled)
        #expect(result.output.isEmpty)
        #expect(result.status == -1)
    }

    @Test func streamingOutputArrivesBeforeExitAndDoesNotAccumulate() async {
        let events = Mutex((data: Data(), idle: 0))
        let (ready, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            await Subprocess.run("/bin/sh", ["-c", "printf 'hello'; sleep 30"], outputLimit: 2,
                                 terminalOutput: true, onOutput: { event in
                events.withLock { value in
                    switch event {
                    case .data(let data): value.data.append(data)
                    case .idle: value.idle += 1; signal.yield(())
                    }
                }
            })
        }
        for await _ in ready { break }
        task.cancel()
        let result = await task.value
        signal.finish()
        #expect(events.withLock { String(decoding: $0.data, as: UTF8.self) } == "hello")
        #expect(events.withLock { $0.idle } >= 1)
        #expect(result.output.isEmpty)
        #expect(!result.truncated)
        #expect(result.cancelled)
    }

    @Test func streamingOutputTimeoutStopsSilentChild() async {
        let result = await Subprocess.run("/bin/sh", ["-c", "sleep 30"],
                                          terminalOutput: true, outputTimeout: 0.1, onOutput: { _ in })
        #expect(result.timedOut)
    }

    @Test func heldInputStaysOpenUntilStop() async {
        let started = ProcessInfo.processInfo.systemUptime
        let result = await Subprocess.run("/bin/sh", ["-c", "cat; printf eof"], input: "payload",
                                          timeout: 0.3, holdInput: true)
        #expect(result.timedOut)
        #expect(result.output.hasPrefix("payload"))
        #expect(ProcessInfo.processInfo.systemUptime - started < 2)
    }

}
