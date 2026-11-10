import Charts
import SwiftUI

/// Git Insights: commit activity, when and by whom the repository is worked on, and where lines change.
/// Reads two bounded `git log` commands when shown and keeps the result until Refresh.
struct ProjectGitInsightsView: View {
    let root: String
    var inspector = ProjectHistoryInspector()
    let refresh: Int
    @State private var stats: ProjectGitStats?

    var body: some View {
        ScrollView {
            if let stats { ProjectGitInsightsContent(stats: stats) } else { ProgressView("Reading commit statistics…").controlSize(.small) }
        }
        .task(id: refresh) {
            stats = nil
            let value = await inspector.stats(root: root)
            guard !Task.isCancelled else { return }
            stats = value
        }
    }
}

/// Renders collected Git Insights; collects nothing.
struct ProjectGitInsightsContent: View {
    let stats: ProjectGitStats
    private static let tint = AppRoute.projects.tint

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorStyle.spacing) { content(stats) }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func content(_ stats: ProjectGitStats) -> some View {
        ForEach(Array(stats.messages.enumerated()), id: \.offset) { _, message in
            Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
        }
        if stats.stamps.isEmpty {
            ContentUnavailableView("No commits", systemImage: "clock", description: Text("Statistics appear once the repository has commits."))
        } else {
            summary(stats)
            card("Activity", systemImage: "square.grid.3x3.fill", caption: "Commits per day over the last year.") {
                ContributionHeatmap(days: stats.activity(days: 7 * ContributionHeatmap.weeks), tint: Self.tint)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { punchcard(stats); authors(stats) }
                VStack(alignment: .leading, spacing: 12) { punchcard(stats); authors(stats) }
            }
            if !stats.churn.weeks.isEmpty {
                card("Line churn", systemImage: "plusminus", caption: "Lines added and removed per week, latest \(stats.churn.commits) non-merge commits.") {
                    ChurnChart(weeks: stats.churn.weeks)
                }
                card("Most changed files", systemImage: "flame", caption: "Files touched by the most of those commits.") {
                    HotFiles(files: Array(stats.churn.files.prefix(10)))
                }
            }
            Text("Counts cover the latest \(ProjectGitStats.commitLimit.formatted()) commits and line churn the latest \(ProjectGitStats.churnLimit) non-merge commits, read with two local `git log` commands when Insights opens and kept until Refresh. Times use this Mac's time zone.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func summary(_ stats: ProjectGitStats) -> some View {
        ResourceStatsRow(headline: stats.stamps.count.formatted() + (stats.limited ? "+" : ""), unit: "commits", stats: [
            ResourceStat(title: "Contributors", systemImage: "person.2", value: stats.contributors.formatted()),
            ResourceStat(title: "Active days", systemImage: "calendar", value: stats.activeDays().formatted()),
            ResourceStat(title: "Longest streak", systemImage: "flame", value: "\(stats.longestStreak()) d"),
            ResourceStat(title: stats.limited ? "Oldest counted" : "First commit", systemImage: "flag",
                         value: stats.first.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Unavailable"),
            ResourceStat(title: "Latest", systemImage: "clock",
                         value: stats.last.map { $0.formatted(.relative(presentation: .named)) } ?? "Unavailable"),
        ], headlineWidth: 130)
    }

    private func punchcard(_ stats: ProjectGitStats) -> some View {
        card("When", systemImage: "clock", caption: "Commits by weekday and hour.") {
            Punchcard(grid: stats.punchcard(), tint: Self.tint)
        }
    }

    private func authors(_ stats: ProjectGitStats) -> some View {
        let authors = stats.authors(limit: 8)
        return card("Who", systemImage: "person.2", caption: "\(stats.contributors) contributors.") {
            let peak = max(1, authors.map(\.commits).max() ?? 1)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(authors) { author in
                    HStack(spacing: 8) {
                        Text(author.name).font(.caption).lineLimit(1).truncationMode(.tail).frame(width: 110, alignment: .leading)
                            .foregroundStyle(author.name == "Others" ? .secondary : .primary)
                        GeometryReader { proxy in
                            Capsule().fill(author.name == "Others" ? Color.secondary.opacity(0.4) : Self.tint.opacity(0.85))
                                .frame(width: max(4, proxy.size.width * CGFloat(author.commits) / CGFloat(peak)), height: 8)
                                .frame(maxHeight: .infinity)
                        }.frame(height: 14)
                        Text(author.commits.formatted()).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func card(_ title: String, systemImage: String, caption: String, @ViewBuilder content: () -> some View) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Label(title, systemImage: systemImage).font(.headline).foregroundStyle(Self.tint)
                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                content()
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }
}

/// A year of daily commit counts as a week-column grid, Monday at the top, with month labels.
private struct ContributionHeatmap: View {
    static let weeks = 53
    let days: [ProjectDayActivity]
    let tint: Color

    var body: some View {
        let peak = max(1, days.map(\.count).max() ?? 1)
        let calendar = Calendar.current
        // Pad the start so each column begins on Monday.
        let lead = days.first.map { (calendar.component(.weekday, from: $0.date) + 5) % 7 } ?? 0
        let cells: [ProjectDayActivity?] = Array(repeating: nil, count: lead) + days.map { Optional($0) }
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                let columns = (cells.count + 6) / 7
                let step = min(size.width / CGFloat(columns), size.height / 7)
                let side = step * 0.82
                for (index, cell) in cells.enumerated() {
                    guard let cell else { continue }
                    let rect = CGRect(x: CGFloat(index / 7) * step, y: CGFloat(index % 7) * step, width: side, height: side)
                    let level = cell.count == 0 ? 0 : 0.25 + 0.75 * sqrt(Double(cell.count) / Double(peak))
                    context.fill(Path(roundedRect: rect, cornerRadius: side * 0.2),
                                 with: .color(cell.count == 0 ? Color.secondary.opacity(0.12) : tint.opacity(level)))
                }
            }
            .aspectRatio(CGFloat((cells.count + 6) / 7) / 7, contentMode: .fit)
            .accessibilityLabel("\(days.map(\.count).reduce(0, +)) commits in the last year, at most \(peak) in a day")
            HStack(spacing: 4) {
                Text(days.first.map { $0.date.formatted(.dateTime.month(.abbreviated).year()) } ?? "")
                Spacer()
                Text("Less")
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(level == 0 ? Color.secondary.opacity(0.12) : tint.opacity(level))
                        .frame(width: 10, height: 10)
                }
                Text("More")
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Weekday by hour: dot size follows the number of commits.
private struct Punchcard: View {
    let grid: [[Int]]
    let tint: Color
    private static let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        let peak = max(1, grid.flatMap { $0 }.max() ?? 1)
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(Self.days, id: \.self) { Text($0).frame(height: 16) }
                Text(" ").frame(height: 14)
            }.font(.caption2).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                Canvas { context, size in
                    let column = size.width / 24, row = size.height / 7
                    for day in 0..<7 {
                        for hour in 0..<24 {
                            let count = grid[day][hour]
                            let center = CGPoint(x: (CGFloat(hour) + 0.5) * column, y: (CGFloat(day) + 0.5) * row)
                            let radius = count == 0 ? 1 : max(2, min(column, row) * 0.48 * sqrt(Double(count) / Double(peak)))
                            context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                                         with: .color(count == 0 ? Color.secondary.opacity(0.25) : tint.opacity(0.85)))
                        }
                    }
                }
                .frame(height: 16 * 7)
                HStack(spacing: 0) {
                    ForEach([0, 6, 12, 18], id: \.self) { hour in
                        Text("\(hour)h").frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.font(.caption2).foregroundStyle(.secondary).frame(height: 14)
            }
        }
        .frame(minWidth: 300)
    }
}

/// Lines added above the axis and removed below it, per week.
private struct ChurnChart: View {
    let weeks: [ProjectWeekChurn]

    var body: some View {
        Chart {
            ForEach(weeks) { week in
                BarMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Lines", week.added))
                    .foregroundStyle(by: .value("Change", "Added"))
                BarMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Lines", -week.removed))
                    .foregroundStyle(by: .value("Change", "Removed"))
            }
            RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary.opacity(0.4))
        }
        .chartForegroundStyleScale(["Added": Color.green.opacity(0.8), "Removed": Color.red.opacity(0.7)])
        .chartYAxis { AxisMarks { value in
            AxisGridLine()
            AxisValueLabel { if let lines = value.as(Int.self) { Text(abs(lines).formatted(.number.notation(.compactName))) } }
        } }
        .frame(height: 160)
    }
}

/// The most changed files with a bar for their share of commits and their added and removed lines.
private struct HotFiles: View {
    let files: [ProjectFileChurn]

    var body: some View {
        let peak = max(1, files.map(\.commits).max() ?? 1)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(files) { file in
                HStack(spacing: 8) {
                    Text(file.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading).help(file.path)
                    Capsule().fill(Color.orange.opacity(0.75))
                        .frame(width: 90 * CGFloat(file.commits) / CGFloat(peak), height: 6)
                        .frame(width: 90, alignment: .leading)
                    Text("\(file.commits)×").font(.caption).monospacedDigit().frame(width: 34, alignment: .trailing)
                    Text("+\(file.added)").font(.caption).monospacedDigit().foregroundStyle(.green).frame(width: 56, alignment: .trailing)
                    Text("−\(file.removed)").font(.caption).monospacedDigit().foregroundStyle(.red).frame(width: 56, alignment: .trailing)
                }
            }
        }
    }
}
