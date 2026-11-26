import Foundation

public enum ControlProtocol {
    public static let version = 2
    public static func supports(_ version: Int) -> Bool { (1...Self.version).contains(version) }
    public static let requestLimit = 64 * 1024
    public static let responseLimit = 48 * 1024 * 1024
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
    public var name: String?
    public var sections: [String]?
    public var base: String?
    public var against: String?
    public var strict: Bool?
    public init(op: String, limit: Int = 100, port: Int? = nil, url: String? = nil, version: Int = ControlProtocol.version) {
        self.version = version; self.op = op; self.limit = limit; self.port = port; self.url = url
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= ControlProtocol.requestLimit,
              let keys = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(keys.keys).isSubset(of: ["version", "op", "limit", "port", "url", "sort", "app", "since", "until", "kinds", "search", "metric", "resolution", "follow", "action", "ruleID", "duration", "name", "sections", "base", "against", "strict"]) else {
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
              action == nil || (op == "alerts" && ["pause", "resume", "snooze"].contains(action!)) || (op == "baseline" && ["create", "list", "diff", "export"].contains(action!)),
              ruleID == nil || (op == "alerts" && action == "snooze" && UUID(uuidString: ruleID!) != nil),
              action != "snooze" || (ruleID != nil && duration != nil),
              duration == nil || (action == "pause" || action == "snooze"),
              follow != true || (since == nil && until == nil),
              metric == nil || !metric!.isEmpty
        else { throw ControlError.invalidRequest }
        if op == "baseline" {
            guard action != nil, (name?.utf8.count ?? 0) <= 256, (base?.utf8.count ?? 0) <= 4096,
                  (against?.utf8.count ?? 0) <= 4096, (sections?.count ?? 0) <= 11,
                  action == "create" || (name == nil && sections == nil),
                  action == "diff" || (against == nil && strict == nil),
                  action != "export" || base != nil,
                  action != "create" && action != "list" || base == nil else { throw ControlError.invalidRequest }
        }
        guard op != "who" || port != nil else { throw ControlError.invalidRequest }
        let allowed: [String: Set<String>] = [
            "baseline": ["action", "name", "sections", "base", "against", "strict"],
            "ps": ["sort", "app"], "ports": ["port"], "who": ["port"], "open": ["url"],
            "events": ["since", "until", "kinds", "search", "follow"],
            "history": ["since", "until", "metric", "resolution"],
            "alerts": ["action", "ruleID", "duration"]]
        let supplied = Set([(sort != nil, "sort"), (app != nil, "app"), (port != nil, "port"),
            (url != nil, "url"), (since != nil, "since"), (until != nil, "until"),
            (kinds != nil, "kinds"), (search != nil, "search"), (follow != nil, "follow"),
            (metric != nil, "metric"), (resolution != nil, "resolution"),
            (name != nil, "name"), (sections != nil, "sections"), (base != nil, "base"),
            (against != nil, "against"), (strict != nil, "strict"), (action != nil, "action"), (ruleID != nil, "ruleID"), (duration != nil, "duration")]
            .filter { $0.0 }.map { $0.1 })
        guard supplied.isSubset(of: allowed[op] ?? []) else { throw ControlError.invalidRequest }
    }

}

public enum ControlError: String, Error, Codable, Sendable {
    case notFound, invalidRequest, unsupportedVersion, unavailable, unsupportedOperation, responseTooLarge, slowConsumer
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
    public func encoded(version: Int? = nil) throws -> Data {
        var response = self
        if let version { response.version = version }
        let data = try JSONEncoder().encode(response)
        guard data.count < ControlProtocol.responseLimit else { throw ControlError.responseTooLarge }
        return data + Data([10])
    }
}
