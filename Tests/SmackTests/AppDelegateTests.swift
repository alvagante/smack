import AppKit
import Testing
@testable import Smack

@Suite struct AppDelegateTests {
    @Test @MainActor func appDelegateSynchronizesPreferencesOnTermination() {
        let delegate = AppDelegate()
        #expect(delegate.didSynchronizeOnTeardown == false)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        #expect(delegate.didSynchronizeOnTeardown == true)
    }
}
