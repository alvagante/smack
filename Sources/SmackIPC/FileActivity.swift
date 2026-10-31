import Foundation

public struct FileActivityPayload: Codable, Sendable {
    public var output: String
    public var error: String?
    public init(output: String = "", error: String? = nil) {
        self.output = output
        self.error = error
    }
}

