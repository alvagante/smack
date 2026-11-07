import Foundation
import Testing
@testable import Smack

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let english = Locale(identifier: "en_US")

@Test func relativeDatesReadAsElapsedTime() {
    #expect(Formatting.relative(now.addingTimeInterval(-3), to: now, locale: english) == "now")
    #expect(Formatting.relative(now.addingTimeInterval(-30), to: now, locale: english) == "30 seconds ago")
    #expect(Formatting.relative(now.addingTimeInterval(-300), to: now, locale: english) == "5 minutes ago")
    #expect(Formatting.relative(now.addingTimeInterval(-7_200), to: now, locale: english) == "2 hours ago")
    #expect(Formatting.relative(now.addingTimeInterval(-3 * 86_400), to: now, locale: english) == "3 days ago")
    #expect(Formatting.relative(now.addingTimeInterval(600), to: now, locale: english) == "in 10 minutes")
}

@Test func datedAppendsRelativeTimeToTheAbsoluteDate() {
    #expect(Formatting.dated("14:03", now.addingTimeInterval(-120), to: now, locale: english) == "14:03 (2 minutes ago)")
    #expect(Formatting.dated("14:03", now, to: now, locale: english) == "14:03 (now)")
}
