import Foundation
import Testing
@testable import Smack

@Test func timelineParsesUnifiedLogRecordsWithTheirSourceAndFullMessage() throws {
    let text = #"{"timestamp":"2026-11-12 10:15:30.123456+0100","eventMessage":"Something failed\nwith details","messageType":"Error","process":"example","processID":42,"subsystem":"test.subsystem","category":"network"}"#
    let events = TimelineSources.parseLog(text)
    let event = try #require(events.first)
    #expect(event.kind == .systemLog)
    #expect(event.details["message"] == "Something failed\nwith details")
    #expect(event.details["subsystem"] == "test.subsystem")
    #expect(event.processName == "example")
    #expect(event.severity == .warning)
}

@Test func timelineLogArgumentsBoundTheRequestedWindow() {
    let window = DateInterval(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200))
    let arguments = TimelineSources.logArguments(window)
    #expect(arguments.contains("@100"))
    #expect(arguments.contains("@200"))
    #expect(arguments.contains("ndjson"))
}
