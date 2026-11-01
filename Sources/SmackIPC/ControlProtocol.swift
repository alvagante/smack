import Foundation

public enum ControlProtocol {
    public static let version = 1
    public static let requestLimit = 64 * 1024
    public static let responseLimit = 16 * 1024 * 1024
    public static let clientLimit = 8
}

/// Explicit field allowlist. The only controls affect alert delivery.
public struct ControlRequest: Codable, Sendable {
    public var version: Int
    public var op: String
    public var limit: Int
    public var port: Int?
    public var url: String?
    public var sort: String?
    public var app: String?
    public var since: Double?
    public var until: Double?
    public var kinds: [String]?
    public var search: String?
    public var metric: String?
    public var resolution: Double?
    public var follow: Bool?
    public var action: String?
    public var ruleID: String?
    public var duration: Double?
    public init(op: String, limit: Int = 100, port: Int? = nil, url: String? = nil, version: Int = ControlProtocol.version) {
        self.version = version; self.op = op; self.limit = limit; self.port = port; self.url = url
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= ControlProtocol.requestLimit,
              let keys = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(keys.keys).isSubset(of: ["version", "op", "limit", "port", "url", "sort", "app", "since", "until", "kinds", "search", "metric", "resolution", "follow", "action", "ruleID", "duration"]) else {
            throw ControlError.invalidRequest
        }
        let request = try JSONDecoder().decode(Self.self, from: data)
        guard (1...1000).contains(request.limit),
              request.port == nil || (1...65535).contains(request.port!),
              request.sort == nil || ["cpu", "memory"].contains(request.sort!) else { throw ControlError.invalidRequest }
        try request.validate()
        return request
    }
    public func validate() throws {
        guard (1...1000).contains(limit), port == nil || (1...65535).contains(port!),
              sort == nil || ["cpu", "memory"].contains(sort!),
              since == nil || (since!.isFinite && (0...1e12).contains(since!)),
              until == nil || (until!.isFinite && (0...1e12).contains(until!)),
              since == nil || until == nil || since! <= until!,
              resolution == nil || (resolution!.isFinite && (1...86400).contains(resolution!)),
              duration == nil || (duration!.isFinite && (1...604800).contains(duration!)),
              (search?.utf8.count ?? 0) <= 256, (kinds?.count ?? 0) <= 64,
              follow != true || op == "events",
              action == nil || (op == "alerts" && ["pause", "resume", "snooze"].contains(action!)),
              ruleID == nil || (op == "alerts" && action == "snooze" && UUID(uuidString: ruleID!) != nil),
              action != "snooze" || (ruleID != nil && duration != nil),
              duration == nil || (action == "pause" || action == "snooze"),
              follow != true || (since == nil && until == nil),
              metric == nil || !metric!.isEmpty
        else { throw ControlError.invalidRequest }
        let allowed: [String: Set<String>] = [
            "ps": ["sort", "app"], "ports": ["port"], "open": ["url"],
            "events": ["since", "until", "kinds", "search", "follow"],
            "history": ["since", "until", "metric", "resolution"],
            "alerts": ["action", "ruleID", "duration"]]
        let supplied = Set([(sort != nil, "sort"), (app != nil, "app"), (port != nil, "port"),
            (url != nil, "url"), (since != nil, "since"), (until != nil, "until"),
            (kinds != nil, "kinds"), (search != nil, "search"), (follow != nil, "follow"),
            (metric != nil, "metric"), (resolution != nil, "resolution"),
            (action != nil, "action"), (ruleID != nil, "ruleID"), (duration != nil, "duration")]
            .filter { $0.0 }.map { $0.1 })
        guard supplied.isSubset(of: allowed[op] ?? []) else { throw ControlError.invalidRequest }
    }

}

public enum ControlError: String, Error, Codable, Sendable {
    case invalidRequest, unsupportedVersion, unavailable, unsupportedOperation, responseTooLarge, slowConsumer
}

/// Small deliberately projected records, shared with the CLI without linking app models.
public struct ControlRecord: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var fields: [String: String]
    public init(id: String, title: String, fields: [String: String] = [:]) {
        self.id = id; self.title = title; self.fields = fields
    }
}

public struct ControlResponse: Codable, Sendable {
    public var version = ControlProtocol.version
    public var requestedVersion: Int?
    public var records: [ControlRecord] = []
    public var metadata: [String: String]?
    public var error: ControlError?
    public var end = true
    public init(records: [ControlRecord] = [], error: ControlError? = nil, requestedVersion: Int? = nil) {
        self.records = records; self.error = error; self.requestedVersion = requestedVersion
    }
    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count < ControlProtocol.responseLimit else { throw ControlError.responseTooLarge }
        return data + Data([10])
    }
}
