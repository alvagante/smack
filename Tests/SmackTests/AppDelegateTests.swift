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

    @Test @MainActor func commandQMenuTerminatesApplication() throws {
        var terminationRequests = 0
        let delegate = AppDelegate(terminateApplication: { terminationRequests += 1 })
        let previousMenu = NSApplication.shared.mainMenu
        defer { NSApplication.shared.mainMenu = previousMenu }
        delegate.configureMainMenu()

        let appMenu = try #require(NSApplication.shared.mainMenu?.items.first?.submenu)
        let quitItem = try #require(appMenu.items.first { $0.keyEquivalent == "q" })
        #expect(quitItem.keyEquivalentModifierMask == .command)
        #expect(quitItem.target === delegate)

        let action = try #require(quitItem.action)
        #expect(NSApplication.shared.sendAction(action, to: quitItem.target, from: quitItem))
        #expect(terminationRequests == 1)
    }

    @Test @MainActor func quitCommandTerminatesApplication() {
        var terminationRequests = 0
        let delegate = AppDelegate(terminateApplication: { terminationRequests += 1 })

        delegate.requestQuit(nil)

        #expect(terminationRequests == 1)
    }
}
