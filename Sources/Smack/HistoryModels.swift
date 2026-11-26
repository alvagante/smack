import Foundation

enum SystemMetric: String, CaseIterable, Identifiable, Sendable {
    case cpu
    case memoryUsedBytes
    case networkReceiveRate
    case networkSendRate
    case diskReadRate
    case diskWriteRate
    case gpuUtilization
    case memoryPressure
    case swapUsedBytes

    var id: Self { self }

    /// Columns and filters that keep unavailable values out of a series, so a chart shows a gap rather than a zero.
    var query: (raw: String, rawFilter: String, minuteAverage: String, minutePeak: String, minuteFilter: String, aggregate: String) {
        switch self {
        case .cpu: ("cpu", "1", "cpu_total / sample_count", "cpu_peak", "1", "cpu")
        case .memoryUsedBytes: ("memory_used", "1", "memory_used_total / sample_count", "memory_used_peak", "1", "memory_used")
        case .networkReceiveRate: ("network_receive", "1", "network_receive_total / sample_count", "network_receive_peak", "1", "network_receive")
        case .networkSendRate: ("network_send", "1", "network_send_total / sample_count", "network_send_peak", "1", "network_send")
        case .diskReadRate: ("disk_read", "1", "disk_read_total / sample_count", "disk_read_peak", "1", "disk_read")
        case .diskWriteRate: ("disk_write", "1", "disk_write_total / sample_count", "disk_write_peak", "1", "disk_write")
        // `gpu_available` is 0 or 1 per sample and the number of available samples per minute row.
        case .gpuUtilization: ("gpu_utilization", "gpu_available = 1", "gpu_utilization_total / gpu_available", "gpu_utilization_peak", "gpu_available > 0", "gpu_utilization")
        case .memoryPressure: ("memory_pressure", "memory_pressure >= 0", "memory_pressure_total / sample_count", "memory_pressure_peak", "memory_pressure_peak >= 0", "memory_pressure")
        case .swapUsedBytes: ("swap_used", "1", "swap_used_total / sample_count", "swap_used_peak", "1", "swap_used")
        }
    }
}

enum ProcessMetric: String, CaseIterable, Sendable {
    case cpuUsage
    case memoryBytes
    case diskReadRate
    case diskWriteRate
    case wakeups

    var columns: (raw: String, total: String, peak: String) {
        switch self {
        case .cpuUsage: ("cpu", "cpu_total", "cpu_peak")
        case .memoryBytes: ("memory", "memory_total", "memory_peak")
        case .diskReadRate: ("disk_read", "disk_read_total", "disk_read_peak")
        case .diskWriteRate: ("disk_write", "disk_write_total", "disk_write_peak")
        case .wakeups: ("wakeups", "wakeups_total", "wakeups_peak")
        }
    }
}

/// Result of measuring the local history database.
struct StorageUsage: Sendable, Equatable {
    struct Category: Sendable, Equatable, Identifiable {
        enum Kind: String, Sendable { case system = "System metrics", processes = "Process metrics", events = "Activity events" }
        var kind: Kind
        var bytes: Int
        var rows: Int
        var oldest: Date?
        var id: Kind { kind }

        /// Measured growth rate, from the oldest stored row to now; nil until an hour of data exists.
        func bytesPerHour(now: Date) -> Int? {
            guard let oldest, now.timeIntervalSince(oldest) >= 3_600 else { return nil }
            return Int(Double(bytes) / (now.timeIntervalSince(oldest) / 3_600))
        }
    }

    var categories: [Category]
    var usedBytes: Int
    var fileBytes: Int
    var measuredAt: Date
}

enum HistoryExportFormat: String, Sendable {
    case json
    case csv
}

enum HistoryRepositoryError: LocalizedError, Equatable {
    case sqlite(code: Int32, message: String)
    case unsupportedSchemaVersion(Int)
    case backupFailed(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let code, let message): "SQLite error \(code): \(message)"
        case .unsupportedSchemaVersion(let version): "Unsupported history schema version \(version)."
        case .backupFailed(let message): "The history backup before migrating failed: \(message)"
        }
    }
}
