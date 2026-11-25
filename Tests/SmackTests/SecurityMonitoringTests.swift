import Foundation
import Testing
@testable import Smack

private actor SecurityControllerSpy: SecurityMonitoringControlling {
    let events: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init() {
        var continuation: AsyncStream<String>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func restoreSecurityCache() async { continuation.yield("restore") }
    func updateFeatureSettings(_ value: CollectionSettings) async { continuation.yield("update") }
    func scanPersistence(hourly: Bool) async { continuation.yield("scan") }
    func stop() async { continuation.yield("stop") }
}

@MainActor
@Test func securityMonitoringOwnsStartSettingsAndStopLifecycle() async {
    let controller = SecurityControllerSpy()
    let monitoring = SecurityMonitoring(controller: controller)
    var settings = CollectionSettings()
    settings.security.watchPersistence = false
    var events = controller.events.makeAsyncIterator()

    monitoring.start(settings: settings)
    var startEvents: Set<String> = []
    while startEvents.count < 2 {
        guard let event = await events.next() else { break }
        startEvents.insert(event)
    }
    #expect(startEvents == ["restore", "update"])

    monitoring.apply(settings: settings)
    let update = await events.next()
    #expect(update == "update")

    monitoring.stop()
    let stop = await events.next()
    #expect(stop == "stop")
}
