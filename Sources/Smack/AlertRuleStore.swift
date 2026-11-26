import Combine
import Foundation

@MainActor
final class AlertRuleStore: ObservableObject {
    @Published private(set) var rules: [AlertRule] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var recoveryNotice: String?
    private let fileURL: URL
    private let onChange: ([AlertRule]) -> Void

    init(fileURL: URL? = nil, onChange: @escaping ([AlertRule]) -> Void = { _ in }) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Smack/alerts.json")
        self.onChange = onChange
        load()
        onChange(rules)
    }

    func update(_ change: (inout [AlertRule]) -> Void) {
        var updated = rules
        change(&updated)
        for index in updated.indices { updated[index].validate() }
        do {
            try persist(updated)
            rules = updated
            errorMessage = nil
            onChange(updated)
        } catch {
            errorMessage = "Failed to save alerts: \(error.localizedDescription)"
        }
    }

    func dismissRecoveryNotice() { recoveryNotice = nil }

    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if (error as NSError).domain == NSCocoaErrorDomain,
               (error as NSError).code == NSFileReadNoSuchFileError {
                rules = AlertRule.templates
                do { try persist(rules) } catch { errorMessage = "Failed to save alerts: \(error.localizedDescription)" }
            } else {
                errorMessage = "Failed to read alerts: \(error.localizedDescription)"
            }
            return
        }
        do {
            rules = try JSONDecoder().decode([AlertRule].self, from: data)
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let backup = fileURL.appendingPathExtension("corrupt-" + stamp + "-" + UUID().uuidString)
            do {
                try FileManager.default.moveItem(at: fileURL, to: backup)
                rules = AlertRule.templates
                try persist(rules)
                recoveryNotice = "Unreadable alert rules were saved as \(backup.lastPathComponent). Disabled templates have been restored."
            } catch {
                errorMessage = "Failed to recover alerts: \(error.localizedDescription)"
            }
        }
    }

    private func persist(_ rules: [AlertRule]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rules).write(to: fileURL, options: .atomic)
    }
}
