import AppIntents
import Foundation
import SmackIPC

struct SmackSnapshotEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Smack Snapshot")
    static let defaultQuery = SmackSnapshotQuery()
    var id: String
    @Property(title: "Name") var name: String
    @Property(title: "Kind") var kind: String
    @Property(title: "PID") var pid: Int?
    @Property(title: "Port") var port: Int?
    @Property(title: "CPU Percent") var cpuPercent: Double?
    @Property(title: "Memory Bytes") var memoryBytes: Double?
    @Property(title: "Timestamp") var timestamp: Date?
    @Property(title: "Event Kind") var eventKind: String?
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(record: ControlRecord, kind: String) {
        id = kind + ":" + record.id
        name = record.title; self.kind = kind
        pid = record.fields["pid"].flatMap(Int.init)
        port = record.fields["port"].flatMap(Int.init)
        cpuPercent = record.fields["cpuPercent"].flatMap(Double.init)
        memoryBytes = (record.fields["memoryBytes"] ?? record.fields["memoryUsedBytes"]).flatMap(Double.init)
        timestamp = record.fields["timestamp"].flatMap { try? Date($0, strategy: .iso8601) }
        eventKind = record.fields["kind"]
    }
}

struct SmackSnapshotQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [SmackSnapshotEntity] {
        guard AutomationSnapshot.store?.settingsStore.settings.automation.appIntentsEnabled == true else { throw ControlError.unavailable }
        return ["status", "ps", "ports", "events"].flatMap { kind in
            let response = AutomationSnapshot.response(ControlRequest(op: kind, limit: 1000))
            return response.records.map { SmackSnapshotEntity(record: $0, kind: kind) }
        }.filter { identifiers.contains($0.id) }
    }
}

enum SmackProcessMetric: String, AppEnum {
    case cpu, memory
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Process Metric")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.cpu: "CPU", .memory: "Memory"]
}

enum SmackPage: String, AppEnum {
    case summary, cpu, memory, apps, ports, timeline, history, security, settings
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Smack Page")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .summary: "Summary", .cpu: "CPU", .memory: "Memory", .apps: "Applications",
        .ports: "Network Ports", .timeline: "Timeline", .history: "History",
        .security: "Security", .settings: "Settings"]
}

@MainActor
private func intentRecords(_ request: ControlRequest) async throws -> [SmackSnapshotEntity] {
    guard AutomationSnapshot.store?.settingsStore.settings.automation.appIntentsEnabled == true else { throw ControlError.unavailable }
    let response = await AutomationSnapshot.query(request)
    if let error = response.error { throw error }
    return response.records.map { SmackSnapshotEntity(record: $0, kind: request.op) }
}

struct GetSystemStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get System Status"
    static let openAppWhenRun = false
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SmackSnapshotEntity> {
        let values = try await intentRecords(ControlRequest(op: "status"))
        guard let value = values.first else { throw ControlError.unavailable }
        return .result(value: value)
    }
}

struct GetTopProcessesIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Top Processes"
    static let openAppWhenRun = false
    @Parameter(title: "Metric", default: .cpu) var metric: SmackProcessMetric
    @Parameter(title: "Count", default: 10) var count: Int
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[SmackSnapshotEntity]> {
        guard (1...1000).contains(count) else { throw ControlError.invalidRequest }
        var request = ControlRequest(op: "ps", limit: count)
        request.sort = metric.rawValue
        return .result(value: try await intentRecords(request))
    }
}

struct WhoListensOnPortIntent: AppIntent {
    static let title: LocalizedStringResource = "Who Listens On Port"
    static let openAppWhenRun = false
    @Parameter(title: "Port") var port: Int
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[SmackSnapshotEntity]> {
        guard (1...65535).contains(port) else { throw ControlError.invalidRequest }
        return .result(value: try await intentRecords(ControlRequest(op: "ports", limit: 1000, port: port)))
    }
}

struct GetRecentEventsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Recent Events"
    static let openAppWhenRun = false
    @Parameter(title: "Since (seconds)", default: 3600) var since: Int
    @Parameter(title: "Kinds (comma separated)", default: "") var kinds: String
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[SmackSnapshotEntity]> {
        guard (1...604800).contains(since) else { throw ControlError.invalidRequest }
        let names = kinds.isEmpty ? [] : kinds.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard names.allSatisfy({ ActivityEventKind(rawValue: $0) != nil }) else { throw ControlError.invalidRequest }
        var request = ControlRequest(op: "events", limit: 1000)
        request.since = Date().addingTimeInterval(-Double(since)).timeIntervalSince1970
        request.kinds = names.isEmpty ? nil : names
        let values = try await intentRecords(request)
        return .result(value: values)
    }
}

struct OpenSmackPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Smack Page"
    static let openAppWhenRun = true
    @Parameter(title: "Page", default: .summary) var page: SmackPage
    @MainActor
    func perform() async throws -> some IntentResult {
        guard AutomationSnapshot.store?.settingsStore.settings.automation.appIntentsEnabled == true else { throw ControlError.unavailable }
        let response = AutomationSnapshot.response(ControlRequest(op: "open", url: "smack://" + page.rawValue))
        if let error = response.error { throw error }
        return .result()
    }
}

struct SmackShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: GetSystemStatusIntent(), phrases: ["Get system status with \(.applicationName)"],
                    shortTitle: "System Status", systemImageName: "waveform.path.ecg")
        AppShortcut(intent: OpenSmackPageIntent(), phrases: ["Open \(.applicationName)"],
                    shortTitle: "Open Smack", systemImageName: "menubar.rectangle")
    }
}
