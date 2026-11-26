import AppIntents
import Foundation

struct Phase0StatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Phase 0 Status"
    static var description = IntentDescription("Read a fixed cached probe value without collecting data.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult & ReturnsValue<String> { .result(value: "cached probe") }
}
