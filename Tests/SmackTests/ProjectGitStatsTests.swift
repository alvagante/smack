import Foundation
import Synchronization
import AppKit
import SwiftUI
import Testing
@testable import Smack

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    return calendar
}

/// 2026-11-09 is a Monday.
private let monday = Date(timeIntervalSince1970: 1_794_182_400)

@Test func gitStatsParseAuthorsAndDatesSkippingMalformedLines() {
    let output = "\(Int(monday.timeIntervalSince1970) + 3_600)\0Ada\n\(Int(monday.timeIntervalSince1970) - 86_400)\0Linus\ngarbage\n\n"
    let stamps = ProjectGitStats.parseLog(output)
    #expect(stamps.map(\.author) == ["Ada", "Linus"])
    #expect(stamps[0].date == monday.addingTimeInterval(3_600))
}

@Test func gitStatsAggregateActivityPunchcardAuthorsAndStreak() {
    let hour: TimeInterval = 3_600, day: TimeInterval = 86_400
    let stamps = [
        ProjectCommitStamp(date: monday.addingTimeInterval(9 * hour), author: "Ada"),
        ProjectCommitStamp(date: monday.addingTimeInterval(10 * hour), author: "Ada"),
        ProjectCommitStamp(date: monday.addingTimeInterval(-day + 9 * hour), author: "Linus"),
        ProjectCommitStamp(date: monday.addingTimeInterval(-2 * day + 23 * hour), author: "Ada"),
        ProjectCommitStamp(date: monday.addingTimeInterval(-10 * day), author: "Grace"),
    ]
    let stats = ProjectGitStats(stamps: stamps, limited: false)
    let activity = stats.activity(days: 14, now: monday.addingTimeInterval(12 * hour), calendar: utc)
    #expect(activity.count == 14)
    #expect(activity.last?.count == 2, "today holds both of Monday's commits")
    #expect(activity.map(\.count).reduce(0, +) == 5)
    let punchcard = stats.punchcard(calendar: utc)
    #expect(punchcard[0][9] == 1 && punchcard[0][10] == 1, "Monday is the first row")
    #expect(punchcard[6][9] == 1, "Sunday is the last row")
    #expect(punchcard[5][23] == 1)
    #expect(stats.authors(limit: 2) == [ProjectAuthorShare(name: "Ada", commits: 3), ProjectAuthorShare(name: "Others", commits: 2)])
    #expect(stats.activeDays(calendar: utc) == 4)
    #expect(stats.longestStreak(calendar: utc) == 3)
    #expect(stats.first == monday.addingTimeInterval(-10 * day))
}

@Test func gitStatsParseNumstatIntoWeeklyChurnAndHotFiles() {
    let week: TimeInterval = 7 * 86_400
    let output = """
    \u{1}\(Int(monday.timeIntervalSince1970) + 100)

    10\t2\tSources/App.swift
    -\t-\tAssets/logo.png
    3\t0\tREADME.md
    \u{1}\(Int(monday.timeIntervalSince1970 - week) + 100)

    5\t5\tSources/App.swift
    \u{1}\(Int(monday.timeIntervalSince1970 - week) + 200)
    """
    let churn = ProjectGitStats.parseNumstat(output, calendar: utc)
    #expect(churn.weeks.map(\.added) == [5, 13])
    #expect(churn.weeks.map(\.removed) == [5, 2])
    #expect(churn.weeks.first?.start == monday.addingTimeInterval(-week))
    #expect(churn.files.first == ProjectFileChurn(path: "Sources/App.swift", commits: 2, added: 15, removed: 7))
    #expect(churn.files.contains { $0.path == "Assets/logo.png" && $0.commits == 1 && $0.added == 0 })
    #expect(churn.commits == 3)
}

/// Opening Insights runs exactly two bounded `git log` commands; nothing computes renames or reads more history.
@Test func gitStatsRunTwoBoundedLogCommands() async {
    let calls = Mutex<[[String]]>([])
    let inspector = ProjectHistoryInspector(run: { _, arguments in
        calls.withLock { $0.append(arguments) }
        return .init(status: 0, output: "", error: "")
    })
    let stats = await inspector.stats(root: "/repo")
    let commands = calls.withLock { $0 }
    #expect(commands.count == 2)
    #expect(commands.allSatisfy { $0.first == "log" })
    #expect(commands[0].contains("-\(ProjectGitStats.commitLimit)"))
    #expect(commands[1].contains("-\(ProjectGitStats.churnLimit)") && commands[1].contains("--numstat") && commands[1].contains("--no-renames"))
    #expect(stats.stamps.isEmpty && stats.messages.isEmpty)
}

@Test @MainActor func gitInsightsRenderAtPanelWidths() throws {
    let now = Date()
    // Deterministic spread: commits on most weekdays over a year, three authors.
    let authors = ["Ada", "Linus", "Grace", "Ken"]
    let stamps: [ProjectCommitStamp] = (0..<900).map { (index: Int) -> ProjectCommitStamp in
        let days = Double(index * 37 % 360), hours = Double(index * 7 % 14 + 8)
        let author = authors[index % (index % 5 == 0 ? 4 : 2)]
        return ProjectCommitStamp(date: now.addingTimeInterval(-days * 86_400 - hours * 3_600), author: author)
    }
    let weeks: [ProjectWeekChurn] = (0..<20).map { (week: Int) -> ProjectWeekChurn in
        ProjectWeekChurn(start: now.addingTimeInterval(-Double(week) * 7 * 86_400), added: 40 + week * 13 % 90, removed: 10 + week * 7 % 60)
    }
    let files: [ProjectFileChurn] = (0..<10).map { (file: Int) -> ProjectFileChurn in
        ProjectFileChurn(path: "Sources/Smack/Views/File\(file).swift", commits: 30 - file * 2, added: 400 - file * 30, removed: 120 - file * 9)
    }
    let churn = ProjectGitStats.Churn(weeks: weeks, files: files, commits: 500)
    let stats = ProjectGitStats(stamps: stamps, limited: false, churn: churn)
    for width in [700.0, 1100.0] {
        let host = NSHostingView(rootView: ProjectGitInsightsContent(stats: stats).padding().frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= width + 1)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("smack-git-insights-\(Int(width)).png"))
        }
    }
}
