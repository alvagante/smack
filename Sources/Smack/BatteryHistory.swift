import Foundation
import SQLite3

/// Battery history read from macOS's own PowerLog, the database behind the Battery pane of System Settings.
/// Smack stores nothing: every page visit reads the last weeks back from the system.
struct BatteryHistory: Sendable, Equatable {
    struct Level: Sendable, Equatable {
        let date: Date
        let percent: Double
        let charging: Bool
    }

    struct ScreenOnHour: Sendable, Equatable {
        let date: Date
        let seconds: Double
    }

    /// One daily battery gauge report.
    struct Daily: Sendable, Equatable {
        let date: Date
        var cycleCount: Int?
        var minimumCharge: Double?
        var maximumCharge: Double?
        var maximumCapacityPercent: Double?
    }

    struct Telemetry: Sendable, Equatable {
        let date: Date
        var temperature: Double?
        var systemPowerWatts: Double?
    }

    /// Nil means the source table could not be read, empty means it had no rows in range.
    var levels: [Level]?
    var screenOn: [ScreenOnHour]?
    var daily: [Daily]?
    var telemetry: [Telemetry]?
    /// The live write-ahead log could not be read, so the last hours may be missing.
    var stale = false
    var truncated = false
    var error: String?
}

struct BatteryHistoryReader: Sendable {
    static let defaultPath = "/private/var/db/powerlog/Library/BatteryLife/CurrentPowerlog.PLSQL"
    var path = Self.defaultPath
    static let rowLimit = 20_000

    func read(now: Date = Date()) -> BatteryHistory {
        var history = BatteryHistory()
        guard FileManager.default.fileExists(atPath: path) else {
            history.error = "macOS battery history is not available on this Mac."
            return history
        }
        // Read-only, including the WAL that holds the last hours. powerd is the only writer.
        var db = open(path, immutable: false)
        if db == nil {
            db = open(path, immutable: true)
            history.stale = db != nil
        }
        guard let db else {
            history.error = "macOS battery history could not be opened."
            return history
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        let since = now.addingTimeInterval(-31 * 86_400).timeIntervalSince1970
        var truncated = false

        history.levels = rows(db, "SELECT timestamp, Level, IsCharging FROM PLBatteryAgent_EventBackward_BatteryUI WHERE timestamp >= ? ORDER BY timestamp DESC", since, truncated: &truncated) { s in
            BatteryHistory.Level(date: date(s, 0), percent: sqlite3_column_double(s, 1), charging: sqlite3_column_int(s, 2) != 0)
        }
        history.screenOn = rows(db, "SELECT timestamp, ScreenOn FROM PLDisplayAgent_Aggregate_ScreenOn WHERE timestamp >= ? ORDER BY timestamp DESC", since, truncated: &truncated) { s in
            // Aggregates are stamped a few seconds off the hour; round to the hour they cover.
            let hour = (sqlite3_column_double(s, 0) / 3600).rounded() * 3600
            return BatteryHistory.ScreenOnHour(date: Date(timeIntervalSince1970: hour), seconds: min(sqlite3_column_double(s, 1), 3600))
        }
        history.daily = rows(db, "SELECT timestamp, CycleCount, DailyMinSoc, DailyMaxSoc, MaximumCapacityPercent FROM PLBatteryAgent_EventNone_BatteryConfig WHERE timestamp >= ? ORDER BY timestamp DESC", since, truncated: &truncated) { s in
            BatteryHistory.Daily(date: date(s, 0), cycleCount: int(s, 1), minimumCharge: double(s, 2), maximumCharge: double(s, 3),
                                 maximumCapacityPercent: double(s, 4).flatMap { $0 > 0 ? $0 : nil })
        }
        history.telemetry = rows(db, "SELECT timestamp, Temperature, SystemPower FROM PLBatteryAgent_EventBackward_Battery WHERE timestamp >= ? ORDER BY timestamp DESC", since, truncated: &truncated) { s in
            BatteryHistory.Telemetry(date: date(s, 0), temperature: double(s, 1), systemPowerWatts: double(s, 2).map { max(0, $0 / 1000) })
        }
        if [history.levels == nil, history.screenOn == nil, history.daily == nil, history.telemetry == nil].allSatisfy({ $0 }) {
            history.error = "macOS battery history uses a format this version of Smack does not read."
        }
        history.truncated = truncated
        return history
    }

    private func open(_ path: String, immutable: Bool) -> OpaquePointer? {
        var components = URLComponents(url: URL(fileURLWithPath: path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: immutable ? "immutable" : "mode", value: immutable ? "1" : "ro")]
        var db: OpaquePointer?
        guard sqlite3_open_v2(components.string!, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              // Opening is lazy; touching the schema proves the file is readable.
              sqlite3_exec(db, "SELECT count(*) FROM sqlite_master", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    /// Each query stands alone, so a table missing on another macOS version disables only its own card.
    private func rows<T>(_ db: OpaquePointer, _ sql: String, _ since: Double, truncated: inout Bool, _ map: (OpaquePointer) -> T) -> [T]? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql + " LIMIT \(Self.rowLimit + 1)", -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        sqlite3_bind_double(statement, 1, since)
        var result: [T] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            result.append(map(statement))
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { return nil }
        if result.count > Self.rowLimit {
            truncated = true
            result.removeLast()
        }
        return result.reversed()
    }

    private func date(_ s: OpaquePointer, _ column: Int32) -> Date { Date(timeIntervalSince1970: sqlite3_column_double(s, column)) }
    private func double(_ s: OpaquePointer, _ column: Int32) -> Double? {
        sqlite3_column_type(s, column) == SQLITE_NULL ? nil : sqlite3_column_double(s, column)
    }
    private func int(_ s: OpaquePointer, _ column: Int32) -> Int? {
        sqlite3_column_type(s, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, column))
    }
}

/// Figures derived from the level samples.
enum BatteryAnalysis {
    /// Samples further apart than this are a gap (sleep with logging off, or shutdown), not a measured interval.
    static let maximumGap: TimeInterval = 20 * 60

    struct Session: Sendable, Equatable, Identifiable {
        var id: Date { start }
        let start: Date
        let end: Date
        let startPercent: Double
        let endPercent: Double
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    struct Day: Sendable, Equatable, Identifiable {
        var id: Date { date }
        let date: Date
        var onBattery: TimeInterval = 0
        var charging: TimeInterval = 0
        var above80: TimeInterval = 0
        var above95: TimeInterval = 0
        var discharged: Double = 0
        var screenOn: TimeInterval = 0
        /// Average drain while on battery, in percent per hour.
        var dischargeRate: Double? { onBattery >= 15 * 60 ? discharged / (onBattery / 3600) : nil }
    }

    /// Runs of charging samples, from the last sample before charging began to the first one after it stopped.
    /// A gap in the samples ends the run at the last sample seen.
    static func sessions(_ levels: [BatteryHistory.Level]) -> [Session] {
        var sessions: [Session] = []
        var open: BatteryHistory.Level?
        var previous: BatteryHistory.Level?
        func close(at end: BatteryHistory.Level?) {
            if let start = open, let end, end.date > start.date {
                sessions.append(Session(start: start.date, end: end.date, startPercent: start.percent, endPercent: end.percent))
            }
            open = nil
        }
        for level in levels {
            let contiguous = previous.map { level.date.timeIntervalSince($0.date) <= maximumGap } ?? false
            if !contiguous { close(at: previous) }
            if level.charging, open == nil {
                open = contiguous && previous?.charging == false ? previous : level
            } else if !level.charging, open != nil {
                close(at: level)
            }
            previous = level
        }
        close(at: previous)
        return sessions
    }

    /// Per-day totals, attributing each interval between samples to the day it starts in.
    static func days(_ levels: [BatteryHistory.Level], screenOn: [BatteryHistory.ScreenOnHour], calendar: Calendar = .current) -> [Day] {
        var days: [Date: Day] = [:]
        func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }
        for (previous, next) in zip(levels, levels.dropFirst()) {
            let interval = next.date.timeIntervalSince(previous.date)
            guard interval > 0, interval <= maximumGap else { continue }
            let key = day(previous.date)
            var value = days[key] ?? Day(date: key)
            if previous.charging { value.charging += interval } else {
                value.onBattery += interval
                value.discharged += max(0, previous.percent - next.percent)
            }
            if previous.percent >= 80 { value.above80 += interval }
            if previous.percent >= 95 { value.above95 += interval }
            days[key] = value
        }
        for hour in screenOn {
            // Aggregates are stamped at the start of the hour they cover.
            let key = day(hour.date)
            var value = days[key] ?? Day(date: key)
            value.screenOn += hour.seconds
            days[key] = value
        }
        return days.values.sorted { $0.date < $1.date }
    }
}
