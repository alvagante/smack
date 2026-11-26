import Foundation

private final class FormatterCache: @unchecked Sendable {
    static let shared = FormatterCache()

    private let lock = NSLock()
    private let byteFormatter: ByteCountFormatter
    private let hourMinuteFormatter: DateComponentsFormatter
    private let minuteSecondFormatter: DateComponentsFormatter

    private init() {
        let bytes = ByteCountFormatter()
        bytes.countStyle = .memory
        byteFormatter = bytes

        let hourMinute = DateComponentsFormatter()
        hourMinute.allowedUnits = [.hour, .minute]
        hourMinute.unitsStyle = .abbreviated
        hourMinuteFormatter = hourMinute

        let minuteSecond = DateComponentsFormatter()
        minuteSecond.allowedUnits = [.minute, .second]
        minuteSecond.unitsStyle = .abbreviated
        minuteSecondFormatter = minuteSecond
    }

    func string(fromByteCount count: Int64) -> String {
        lock.withLock {
            byteFormatter.string(fromByteCount: count)
        }
    }

    func duration(_ value: TimeInterval) -> String? {
        lock.withLock {
            let formatter = value >= 3600 ? hourMinuteFormatter : minuteSecondFormatter
            return formatter.string(from: value)
        }
    }
}

enum Formatting {
    static func percent(_ value: Double) -> String {
        "\(max(0, value).formatted(.number.precision(.fractionLength(value < 10 ? 2 : 1))))%"
    }

    static func bytes(_ value: UInt64) -> String {
        FormatterCache.shared.string(fromByteCount: Int64(clamping: value))
    }

    static func rate(_ value: Double) -> String {
        FormatterCache.shared.string(fromByteCount: Int64(max(0, value))) + "/s"
    }

    static func duration(_ value: TimeInterval?) -> String {
        guard let value, value > 0 else { return "—" }
        return FormatterCache.shared.duration(value) ?? "—"
    }

    static func date(_ value: Date) -> String {
        value.formatted(date: .omitted, time: .standard)
    }
}
