import Foundation

enum Formatting {
    static func percent(_ value: Double) -> String {
        "\(max(0, value).formatted(.number.precision(.fractionLength(value < 10 ? 2 : 1))))%"
    }

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func rate(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .memory) + "/s"
    }

    static func duration(_ value: TimeInterval?) -> String {
        guard let value, value > 0 else { return "—" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = value >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: value) ?? "—"
    }

    static func date(_ value: Date) -> String {
        value.formatted(date: .omitted, time: .standard)
    }
}
