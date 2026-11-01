import AppKit
import Foundation
import SQLite3
import SwiftUI
import Testing
@testable import Smack

private func level(_ minutes: Double, _ percent: Double, _ charging: Bool, start: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> BatteryHistory.Level {
    .init(date: start.addingTimeInterval(minutes * 60), percent: percent, charging: charging)
}

private func makeFixture(_ statements: [String]) throws -> String {
    let path = "/tmp/smack-powerlog-\(UUID().uuidString).PLSQL"
    var db: OpaquePointer?
    #expect(sqlite3_open(path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    for sql in statements { #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "\(sql)") }
    return path
}

@Test func batteryHistoryReaderReadsPowerLogTablesIndependently() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let t = now.timeIntervalSince1970
    let path = try makeFixture([
        "CREATE TABLE PLBatteryAgent_EventBackward_BatteryUI (ID INTEGER, timestamp REAL, IsCharging INTEGER, Level REAL)",
        "INSERT INTO PLBatteryAgent_EventBackward_BatteryUI VALUES (1, \(t - 40 * 86_400), 0, 10), (2, \(t - 600), 0, 55), (3, \(t - 240), 1, 54)",
        "CREATE TABLE PLDisplayAgent_Aggregate_ScreenOn (ID INTEGER, timestamp REAL, timeInterval REAL, ScreenOn REAL)",
        "INSERT INTO PLDisplayAgent_Aggregate_ScreenOn VALUES (1, \(t - 3600 * 5 - 14), 3600, 4000)",
        "CREATE TABLE PLBatteryAgent_EventNone_BatteryConfig (ID INTEGER, timestamp REAL, CycleCount INTEGER, DailyMinSoc INTEGER, DailyMaxSoc INTEGER, MaximumCapacityPercent INTEGER)",
        "INSERT INTO PLBatteryAgent_EventNone_BatteryConfig VALUES (1, \(t - 86_400), 92, 21, 100, 99), (2, \(t - 3600), 93, NULL, NULL, 0)",
    ])
    defer { try? FileManager.default.removeItem(atPath: path) }
    let history = BatteryHistoryReader(path: path).read(now: now)
    #expect(history.error == nil)
    #expect(!history.stale)
    #expect(history.levels?.map(\.percent) == [55, 54])
    #expect(history.levels?.last?.charging == true)
    #expect(history.screenOn?.first?.seconds == 3600)
    #expect(history.screenOn?.first?.date.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600) == 0)
    #expect(history.daily?.first?.cycleCount == 92)
    #expect(history.daily?.first?.maximumCharge == 100)
    #expect(history.daily?.last?.minimumCharge == nil)
    #expect(history.daily?.last?.maximumCapacityPercent == nil)
    // The battery telemetry table is absent: only that source is unavailable.
    #expect(history.telemetry == nil)
}

@Test func batteryHistoryReaderReportsMissingAndUnknownSources() throws {
    #expect(BatteryHistoryReader(path: "/tmp/does-not-exist-\(UUID().uuidString)").read().error != nil)
    let path = try makeFixture(["CREATE TABLE unrelated (x)"])
    defer { try? FileManager.default.removeItem(atPath: path) }
    let history = BatteryHistoryReader(path: path).read()
    #expect(history.error != nil)
    #expect(history.levels == nil)
}

@Test func batteryChargingSessionsStartBeforePlugInAndSplitAtGaps() {
    let levels = [
        level(0, 40, false), level(6, 38, false), level(12, 45, true), level(18, 60, true), level(24, 70, false),
        level(30, 69, false),
        // An hour of silence ends a session at its last sample.
        level(36, 70, true), level(42, 80, true), level(102, 95, true), level(108, 100, true),
    ]
    let sessions = BatteryAnalysis.sessions(levels)
    #expect(sessions.count == 3)
    #expect(sessions[0].startPercent == 38)
    #expect(sessions[0].endPercent == 70)
    #expect(sessions[1].startPercent == 69)
    #expect(sessions[1].endPercent == 80)
    #expect(sessions[2].startPercent == 95)
    #expect(sessions[2].endPercent == 100)
}

@Test func batteryDaysTotalTimeAtHighChargeDrainAndScreen() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    let levels = [
        level(0, 100, false, start: start), level(10, 96, false, start: start), level(20, 90, false, start: start),
        level(30, 85, false, start: start),
        // Gaps over 20 minutes are not counted.
        level(90, 80, false, start: start),
    ]
    let screen = [BatteryHistory.ScreenOnHour(date: start, seconds: 1800), BatteryHistory.ScreenOnHour(date: start.addingTimeInterval(3600), seconds: 600)]
    let days = BatteryAnalysis.days(levels, screenOn: screen, calendar: calendar)
    #expect(days.count == 1)
    let day = days[0]
    #expect(day.above95 == 1200)
    #expect(day.above80 == 1800)
    #expect(day.onBattery == 1800)
    #expect(day.discharged == 15)
    #expect(day.dischargeRate == 30)
    #expect(day.screenOn == 2400)
}

@Test @MainActor func batteryHistoryPageRenders() async throws {
    let now = Date()
    var history = BatteryHistory()
    if ProcessInfo.processInfo.environment["SMACK_BATTERY_LIVE"] != nil {
        history = BatteryHistoryReader().read(now: now)
    } else {
        history.levels = stride(from: 0.0, to: 30 * 24 * 10, by: 1).map { step in
            let minutes = step * 6
            let percent = 100 - (minutes.truncatingRemainder(dividingBy: 600)) / 8
            return level(minutes - 30 * 24 * 60, percent, minutes.truncatingRemainder(dividingBy: 600) > 480, start: now)
        }
        history.screenOn = (0..<(14 * 24)).map { .init(date: now.addingTimeInterval(Double(-$0) * 3600), seconds: Double($0 % 4) * 900) }
        history.daily = (0..<14).map { .init(date: now.addingTimeInterval(Double(-$0) * 86_400), cycleCount: 100 - $0 / 2,
                                             minimumCharge: Double(20 + $0 * 3), maximumCharge: 100, maximumCapacityPercent: 98) }
        history.telemetry = (0..<120).map { .init(date: now.addingTimeInterval(Double(-$0) * 1200), temperature: 30 + Double($0 % 5), systemPowerWatts: 8 + Double($0 % 7)) }
    }
    for range in BatteryRange.allCases {
        for width in [500.0, 1200.0] {
            let host = NSHostingView(rootView: BatteryHistoryContent(history: history, range: range, now: now)
                .padding().fixedSize(horizontal: false, vertical: true).frame(width: width).background(Color(nsColor: .windowBackgroundColor)))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 1100)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width <= width + 1)
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            if let directory = ProcessInfo.processInfo.environment["SMACK_LAYOUT_PREVIEW_DIR"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try png.write(to: URL(fileURLWithPath: "\(directory)/battery-\(range.rawValue.replacingOccurrences(of: " ", with: ""))-\(Int(width)).png"))
            }
        }
    }
}
