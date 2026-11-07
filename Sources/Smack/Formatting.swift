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

    /// Wakeups per second, for example `12.4/s`.
    static func wakeups(_ value: Double) -> String {
        "\(max(0, value).formatted(.number.precision(.fractionLength(1))))/s"
    }

    /// Process wakeups for lists: "—" when the sandbox cannot read them (they then read as zero).
    static func processWakeups(_ value: Double) -> String {
        if Capabilities.isSandboxed, value == 0 { return "—" }
        return wakeups(value)
    }

    /// Process energy impact for lists: "—" when unavailable or unreadable in the sandbox.
    static func energy(_ value: Double?) -> String {
        if Capabilities.isSandboxed, value == nil || value == 0 { return "—" }
        return value?.formatted(.number.precision(.fractionLength(1))) ?? "—"
    }

    static func pressure(_ value: MemoryPressure) -> String {
        value == .unavailable ? "Unavailable" : value.rawValue.capitalized
    }

    /// History stores pressure as 0, 1 or 2; averages between them round to the nearest level.
    static func pressure(historyValue value: Double) -> String {
        switch value {
        case ..<0.5: "Normal"
        case ..<1.5: "Warning"
        default: "Critical"
        }
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

    /// Human-readable timestamp for session lists and command rows:
    /// - Same calendar day → "14:03"
    /// - Same calendar week → "Mon 14:03"
    /// - Older → "Nov 5 · 14:03"
    static func sessionDate(_ value: Date, relativeTo now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(value, inSameDayAs: now) {
            return value.formatted(date: .omitted, time: .shortened)
        }
        let startOfWeek = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
        if value >= startOfWeek {
            return value.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return value.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// Elapsed time in words: "now", "30 seconds ago", "2 hours ago", "in 10 minutes".
    /// Computed when the view renders; it does not tick on its own.
    static func relative(_ value: Date, to now: Date = Date(), locale: Locale = .autoupdatingCurrent) -> String {
        if abs(value.timeIntervalSince(now)) < 5 { return String(localized: "now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: value, relativeTo: now)
    }

    /// An already formatted date followed by its relative time: "14:03 (2 minutes ago)".
    static func dated(_ absolute: String, _ value: Date, to now: Date = Date(), locale: Locale = .autoupdatingCurrent) -> String {
        "\(absolute) (\(relative(value, to: now, locale: locale)))"
    }
}
