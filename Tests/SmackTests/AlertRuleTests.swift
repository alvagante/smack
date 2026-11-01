import Foundation
import Testing
@testable import Smack

@Test func alertTemplatesAreDisabledAndRoundTrip() throws {
    let rules = AlertRule.templates
    #expect(rules.count == 10)
    #expect(rules.allSatisfy { !$0.enabled })
    #expect(Set(rules.map(\.id)).count == rules.count)
    let decoded = try JSONDecoder().decode([AlertRule].self, from: JSONEncoder().encode(rules))
    #expect(decoded == rules)
}

@Test func alertValidationClampsMetricDomainsAndDurations() {
    var rule = AlertRule(name: "Invalid", enabled: true, kind: .systemThreshold(
        metric: .startupDiskFreeRatio, comparison: .lessThan, value: 2, sustain: -5, clear: -1))
    rule.cooldown = -10
    rule.validate()
    #expect(rule.cooldown == 0)
    #expect(rule.kind == .systemThreshold(metric: .startupDiskFreeRatio, comparison: .lessThan,
                                        value: 1, sustain: 0, clear: 0))
    rule.kind = .processThreshold(metric: .cpu, matcher: ProcessMatcher(anyProcess: true),
                                  comparison: .greaterThan, value: 800, sustain: 10, clear: nil)
    rule.validate()
    #expect(rule.kind == .processThreshold(metric: .cpu, matcher: ProcessMatcher(anyProcess: true),
                                         comparison: .greaterThan, value: 800, sustain: 10, clear: nil))
}

@Test func unknownAlertKindsAndMetricsSurviveAlongsideKnownRules() throws {
    let known = AlertRule.templates[0]
    let knownObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(known)) as? [String: Any])
    for futureKind: [String: Any] in [
        ["futureRule": ["threshold": 123456789012345]],
        ["systemThreshold": ["metric": "futureMetric", "comparison": "greaterThan", "value": 20, "sustain": 5]]
    ] {
        var future = knownObject
        future["id"] = UUID().uuidString
        future["enabled"] = true
        future["kind"] = futureKind
        future["futureField"] = ["keep": [1, 2, 3]]
        let input = try JSONSerialization.data(withJSONObject: [knownObject, future])
        let decoded = try JSONDecoder().decode([AlertRule].self, from: input)
        #expect(decoded[0] == known)
        #expect(!decoded[1].enabled)
        guard case .unknown = decoded[1].kind else {
            Issue.record("Future rule should be unavailable")
            continue
        }
        let output = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [[String: Any]])
        #expect(NSDictionary(dictionary: output[1]) == NSDictionary(dictionary: future))
    }
}

@Test @MainActor func alertStorePersistsOrderAndPublishesOnlySuccessfulChanges() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/alerts.json")
    var updates: [[AlertRule]] = []
    let store = AlertRuleStore(fileURL: url) { updates.append($0) }
    #expect(store.errorMessage == nil)
    store.update { rules in
        rules.reverse()
        rules[0].enabled = true
    }
    let reopened = AlertRuleStore(fileURL: url)
    #expect(reopened.rules == store.rules)
    #expect(updates.count == 2)
    #expect(updates.last == store.rules)
    // A directory at the file path reliably rejects the atomic write.
    let blocked = url.deletingLastPathComponent()
    let failing = AlertRuleStore(fileURL: blocked)
    let before = failing.rules
    failing.update { $0.append(AlertRule.templates[0]) }
    #expect(failing.errorMessage != nil)
    #expect(failing.rules == before)
}

@Test @MainActor func corruptAlertStoreBacksUpOriginalAndRecoversDisabledTemplates() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("alerts.json")
    let original = Data("not JSON".utf8)
    try original.write(to: url)
    let store = AlertRuleStore(fileURL: url)
    #expect(store.errorMessage == nil)
    #expect(store.recoveryNotice != nil)
    #expect(store.rules.count == 10)
    #expect(store.rules.allSatisfy { !$0.enabled })
    let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("alerts.json.corrupt-") }
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: #require(backups.first)) == original)
    #expect(AlertRuleStore(fileURL: url).rules == store.rules)
    store.dismissRecoveryNotice()
    #expect(store.recoveryNotice == nil)
    #expect(AlertRuleStore(fileURL: url).recoveryNotice == nil)
}

@Test func alertSecuritySettingsMigrateAndPersistDisabledSchedule() throws {
    let old = try JSONDecoder().decode(CollectionSettings.self, from: Data(#"{"retentionDays":12}"#.utf8))
    #expect(old.retentionDays == 12)
    #expect(old.recordAlertEvents && old.recordSecurityEvents)
    #expect(old.postureCheckInterval == 21_600)
    #expect(old.watchPersistence && old.controlSocketEnabled)
    var settings = old
    settings.postureCheckInterval = nil
    settings.recordAlertEvents = false
    settings.recordSecurityEvents = false
    settings.watchPersistence = false
    settings.controlSocketEnabled = false
    let decoded = try JSONDecoder().decode(CollectionSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded == settings)
    #expect(!decoded.records(.alerts) && !decoded.records(.security))
    settings.recordActivity = false
    #expect(ActivityEventKind.Group.allCases.allSatisfy { !settings.records($0) })
}

@Test func alertSecurityEventKindsHaveMetadataAndRoundTrip() throws {
    for kind in [ActivityEventKind.alertFired, .postureChanged, .persistenceFileChanged] {
        #expect(!kind.title.isEmpty && !kind.systemImage.isEmpty)
        #expect(try JSONDecoder().decode(ActivityEventKind.self, from: JSONEncoder().encode(kind)) == kind)
    }
    #expect(ActivityEventKind.alertFired.group == .alerts)
    #expect(ActivityEventKind.postureChanged.group == .security)
    #expect(ActivityEventKind.persistenceFileChanged.group == .security)
}
