import Foundation

struct ProjectCommit: Identifiable, Equatable, Sendable {
    let id: String
    let author: String
    let date: Date
    let subject: String
    let references: String
}

struct ProjectHistory: Sendable {
    var commits: [ProjectCommit] = []
    var references = ""
    var remotes = ""
    var messages: [String] = []
}

/// Separate from overview inspection: no history commands run until its section is opened.
struct ProjectHistoryInspector: Sendable {
    var run: ProjectGitInspector.Runner = ProjectGitInspector().run

    func history(root: String) async -> ProjectHistory {
        var history = ProjectHistory()
        let log = await run(root, ["log", "-100", "--date-order", "--format=%H%x00%an%x00%ct%x00%s%x00%D"])
        if let message = Self.failure(log) { history.messages.append(message) }
        else {
            history.commits = log.output.split(whereSeparator: \.isNewline).compactMap { line in
                let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
                guard fields.count == 5, let seconds = Double(fields[2]) else { return nil }
                return ProjectCommit(id: String(fields[0]), author: String(fields[1]),
                    date: Date(timeIntervalSince1970: seconds), subject: String(fields[3]), references: String(fields[4]))
            }
        }
        guard !Task.isCancelled else { return history }
        let refs = await run(root, ["for-each-ref", "--count=200", "--sort=-committerdate",
                                    "--format=%(refname:short) %(objectname:short) %(subject)"])
        if let message = Self.failure(refs) { history.messages.append(message) }
        else { history.references = refs.output }
        guard !Task.isCancelled else { return history }
        let remotes = await run(root, ["remote", "-v"])
        if let message = Self.failure(remotes) { history.messages.append(message) }
        else { history.remotes = remotes.output }
        if log.truncated || refs.truncated || remotes.truncated {
            history.messages.append("Git output limited to 2 MB per command; results may be incomplete.")
        }
        return history
    }

    func commit(root: String, id: String) async -> String {
        // Only object IDs from the history parser can become a revision argument.
        guard (7...64).contains(id.count), id.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            return "Commit unavailable."
        }
        let result = await run(root, ["show", "--no-ext-diff", "--no-textconv", "--format=fuller",
                                      "--stat", "--patch", id, "--"])
        if let message = Self.failure(result) { return message }
        return result.output + (result.truncated ? "\nOutput limited to 2 MB." : "")
    }

    static func failure(_ result: CommandRunner.Result) -> String? {
        if result.cancelled { return "Git was stopped." }
        if result.timedOut { return "Git timed out after 8 seconds." }
        guard result.status == 0 else {
            let text = (result.error + result.output).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "Git information is unavailable." : text
        }
        return nil
    }
}

struct ProjectCommitStamp: Equatable, Sendable {
    let date: Date
    let author: String
}

struct ProjectAuthorShare: Equatable, Sendable, Identifiable {
    let name: String
    let commits: Int
    var id: String { name }
}

struct ProjectFileChurn: Equatable, Sendable, Identifiable {
    let path: String
    var commits: Int
    var added: Int
    var removed: Int
    var id: String { path }
}

struct ProjectWeekChurn: Equatable, Sendable, Identifiable {
    let start: Date
    var added: Int
    var removed: Int
    var id: Date { start }
}

struct ProjectDayActivity: Equatable, Sendable, Identifiable {
    let date: Date
    let count: Int
    var id: Date { date }
}

/// Git Insights for one repository: who committed when, from the latest `commitLimit` commits, and line churn from
/// the latest `churnLimit` non-merge commits. Read once when Insights opens, kept until Refresh.
struct ProjectGitStats: Sendable, Equatable {
    static let commitLimit = 5_000
    static let churnLimit = 500

    var stamps: [ProjectCommitStamp] = []
    /// True when the history is longer than `commitLimit`, so counts cover only the newest commits.
    var limited = false
    var churn = Churn()
    var messages: [String] = []

    struct Churn: Sendable, Equatable {
        var weeks: [ProjectWeekChurn] = []
        var files: [ProjectFileChurn] = []
        var commits = 0
    }

    init(stamps: [ProjectCommitStamp] = [], limited: Bool = false, churn: Churn = Churn()) {
        self.stamps = stamps
        self.limited = limited
        self.churn = churn
    }

    var first: Date? { stamps.map(\.date).min() }
    var last: Date? { stamps.map(\.date).max() }

    /// Commits per day for the `days` days ending today, oldest first, empty days included.
    func activity(days: Int, now: Date = Date(), calendar: Calendar = .current) -> [ProjectDayActivity] {
        let today = calendar.startOfDay(for: now)
        var counts: [Date: Int] = [:]
        for stamp in stamps { counts[calendar.startOfDay(for: stamp.date), default: 0] += 1 }
        return (0..<days).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { ProjectDayActivity(date: $0, count: counts[$0] ?? 0) }
        }
    }

    /// Commits by weekday (Monday first) and hour of day, in the calendar's time zone.
    func punchcard(calendar: Calendar = .current) -> [[Int]] {
        var grid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for stamp in stamps {
            let parts = calendar.dateComponents([.weekday, .hour], from: stamp.date)
            guard let weekday = parts.weekday, let hour = parts.hour else { continue }
            grid[(weekday + 5) % 7][hour] += 1
        }
        return grid
    }

    /// The most frequent authors; past `limit`, the rest are summed as "Others".
    func authors(limit: Int) -> [ProjectAuthorShare] {
        let counts = Dictionary(stamps.map { ($0.author, 1) }, uniquingKeysWith: +)
            .map { ProjectAuthorShare(name: $0.key, commits: $0.value) }
            .sorted { $0.commits != $1.commits ? $0.commits > $1.commits : $0.name < $1.name }
        guard counts.count > limit, limit > 0 else { return counts }
        let top = Array(counts.prefix(limit - 1))
        return top + [ProjectAuthorShare(name: "Others", commits: counts.dropFirst(limit - 1).reduce(0) { $0 + $1.commits })]
    }

    var contributors: Int { Set(stamps.map(\.author)).count }

    func activeDays(calendar: Calendar = .current) -> Int { Set(stamps.map { calendar.startOfDay(for: $0.date) }).count }

    /// The longest run of consecutive days with at least one commit.
    func longestStreak(calendar: Calendar = .current) -> Int {
        let days = Set(stamps.map { calendar.startOfDay(for: $0.date) }).sorted()
        var best = 0, run = 0
        var previous: Date?
        for day in days {
            run = previous.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } == day ? run + 1 : 1
            best = max(best, run)
            previous = day
        }
        return best
    }

    /// `git log --format=%ct%x00%aN` output.
    static func parseLog(_ output: String) -> [ProjectCommitStamp] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, let seconds = Double(fields[0]) else { return nil }
            return ProjectCommitStamp(date: Date(timeIntervalSince1970: seconds), author: String(fields[1]))
        }
    }

    /// `git log --numstat --format=%x01%ct` output: a marker line per commit, then added, removed and path per file.
    /// Binary files count as a change with no lines.
    static func parseNumstat(_ output: String, calendar: Calendar = .current) -> Churn {
        var churn = Churn()
        var weeks: [Date: ProjectWeekChurn] = [:]
        var files: [String: ProjectFileChurn] = [:]
        var week: Date?
        for line in output.split(whereSeparator: \.isNewline) {
            if line.first == "\u{1}" {
                week = Double(line.dropFirst()).flatMap {
                    calendar.dateInterval(of: .weekOfYear, for: Date(timeIntervalSince1970: $0))?.start
                }
                if week != nil { churn.commits += 1 }
                continue
            }
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let week else { continue }
            let added = Int(fields[0]) ?? 0, removed = Int(fields[1]) ?? 0
            let path = String(fields[2])
            weeks[week, default: ProjectWeekChurn(start: week, added: 0, removed: 0)].added += added
            weeks[week]?.removed += removed
            files[path, default: ProjectFileChurn(path: path, commits: 0, added: 0, removed: 0)].commits += 1
            files[path]?.added += added
            files[path]?.removed += removed
        }
        churn.weeks = weeks.values.sorted { $0.start < $1.start }
        churn.files = files.values.sorted {
            $0.commits != $1.commits ? $0.commits > $1.commits
                : $0.added + $0.removed != $1.added + $1.removed ? $0.added + $0.removed > $1.added + $1.removed : $0.path < $1.path
        }
        churn.files = Array(churn.files.prefix(50))
        return churn
    }
}

extension ProjectHistoryInspector {
    /// Two bounded reads: authors and dates of the newest commits, then line counts of the newest non-merge commits
    /// without rename detection. Each command keeps the 8-second and 2 MB caps.
    func stats(root: String) async -> ProjectGitStats {
        var stats = ProjectGitStats()
        let log = await run(root, ["log", "-\(ProjectGitStats.commitLimit)", "--format=%ct%x00%aN"])
        if let message = Self.failure(log) { stats.messages.append(message) }
        else {
            stats.stamps = ProjectGitStats.parseLog(log.output)
            stats.limited = stats.stamps.count >= ProjectGitStats.commitLimit || log.truncated
        }
        guard !Task.isCancelled else { return stats }
        let numstat = await run(root, ["log", "-\(ProjectGitStats.churnLimit)", "--no-merges", "--no-renames", "--numstat",
                                       "--format=%x01%ct"])
        if let message = Self.failure(numstat) { stats.messages.append(message) }
        else { stats.churn = ProjectGitStats.parseNumstat(numstat.output) }
        if log.truncated || numstat.truncated {
            stats.messages.append("Git output limited to 2 MB per command; statistics may be incomplete.")
        }
        return stats
    }
}
