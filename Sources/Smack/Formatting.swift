import Foundation

enum Formatting {
    static func percent(_ value: Double) -> String {
        "\(max(0, value).formatted(.number.precision(.fractionLength(value < 10 ? 2 : 1))))%"
    }

    /// Numeric output only, so zero renders as "0 bytes" instead of "Zero bytes".
    private static func byteString(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: count)
    }

    static func bytes(_ value: UInt64) -> String {
        byteString(Int64(clamping: value))
    }

    static func rate(_ value: Double) -> String {
        byteString(Int64(max(0, value))) + "/s"
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
