import Foundation
import Testing
@testable import Smack

@Test func backgroundWorkReturnsTheResult() async {
    #expect(await BackgroundWork.run { 21 * 2 } == 42)
}

/// Without forwarding, the work never sees cancellation and the time limit fails the test.
@Test(.timeLimit(.minutes(1))) func backgroundWorkForwardsCancellationToTheDetachedTask() async {
    let started = DispatchSemaphore(value: 0)
    let outer = Task {
        await BackgroundWork.run { () -> Bool in
            started.signal()
            while !Task.isCancelled {}
            return true
        }
    }
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { started.wait(); continuation.resume() }
    }
    outer.cancel()
    #expect(await outer.value)
}
