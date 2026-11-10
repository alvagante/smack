import Charts
import SwiftUI

/// A Project's Overview: what state the repository is in, what is running from it, how active it is and what it is
/// built with. Renders data the Detail Page already holds; reads nothing itself.
struct ProjectOverviewView: View {
    let project: ProjectRecord
    let report: ProjectGitReport?
    let inspecting: Bool
    let manifests: [ProjectManifest]?
    /// Requirements matched with installed runtimes; nil while Development environments have not been discovered.
    let matches: [ProjectRuntimeMatch]?
    let servers: [DevServer]
    let containers: [DockerContainer]
    let sessions: [AgentSession]
    let size: UInt64?
    var open: (ProjectSection) -> Void = { _ in }

    private static let tint = AppRoute.projects.tint
    private var git: ProjectGitReport? { report.flatMap { $0.failed ? nil : $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: MonitorStyle.spacing) {
            hero
            if let message = report?.message, report?.failed == true {
                Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { activity.frame(maxWidth: .infinity); workingTree.frame(maxWidth: .infinity) }
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 12) { activity; workingTree }
            }
            runningNow
            stack
            details
            Text("Git status, the last commit and twelve weeks of commit dates are read when you open the repository and stay cached until Refresh. Language files are read once with them. Everything else comes from data Smack already collects.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Hero

    private var languages: [String] {
        var seen: [String] = []
        for name in (manifests ?? []).map(\.language) + project.runtimes.map(\.name) + [project.kind?.rawValue.capitalized].compactMap({ $0 })
        where !seen.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) && name != "direnv" { seen.append(name) }
        return seen
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(project.name).font(.title.weight(.bold)).lineLimit(2).textSelection(.enabled)
                if project.git?.isWorktree == true { Pill(text: "Linked worktree", systemImage: "arrow.triangle.branch", color: .purple) }
                Spacer(minLength: 8)
                if let remote = report?.remoteURL, let url = ProjectRemote.webURL(remote) {
                    Link(destination: url) {
                        Label(url.host().map { $0 + url.path } ?? url.absoluteString, systemImage: "arrow.up.forward.square")
                            .font(.callout).lineLimit(1).truncationMode(.middle)
                    }.help(remote)
                }
            }
            FlowLayout(spacing: 6, lineSpacing: 6) {
                Pill(text: project.git?.branch ?? (project.git == nil ? "Git unavailable" : "Detached HEAD"),
                     systemImage: "arrow.triangle.branch", color: Self.tint)
                sync
                tree
                ForEach(languages, id: \.self) { Pill(text: $0, systemImage: "chevron.left.forwardslash.chevron.right", color: .teal) }
            }
            lastCommit
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Self.tint.opacity(0.14), Self.tint.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Self.tint.opacity(0.2)))
    }

    @ViewBuilder private var sync: some View {
        if let git {
            if let upstream = git.upstream {
                if git.ahead == 0 && git.behind == 0 {
                    Pill(text: "In sync with \(upstream)", systemImage: "checkmark.circle", color: .green)
                } else {
                    Pill(text: [git.ahead > 0 ? "↑\(git.ahead)" : nil, git.behind > 0 ? "↓\(git.behind)" : nil].compactMap { $0 }.joined(separator: " ")
                         + " vs \(upstream)", systemImage: "arrow.up.arrow.down", color: git.behind > 0 ? .orange : .blue)
                }
            } else {
                Pill(text: "No upstream", systemImage: "icloud.slash", color: .secondary)
            }
        } else if inspecting {
            Pill(text: "Reading status…", systemImage: "hourglass", color: .secondary)
        }
    }

    @ViewBuilder private var tree: some View {
        if let git {
            if git.conflicted > 0 {
                Pill(text: "\(git.conflicted) conflicts", systemImage: "exclamationmark.triangle.fill", color: .red)
            } else if git.isDirty {
                Pill(text: "\(git.changes) uncommitted \(git.changes == 1 ? "change" : "changes")", systemImage: "pencil", color: .orange)
            } else {
                Pill(text: "Clean", systemImage: "checkmark.seal", color: .green)
            }
        }
    }

    @ViewBuilder private var lastCommit: some View {
        if let git, let subject = git.lastSubject {
            VStack(alignment: .leading, spacing: 4) {
                Text(subject).font(.body.weight(.medium)).lineLimit(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    Text([git.lastAuthor, git.lastHash, git.lastCommit.map { Formatting.relative($0) }].compactMap { $0 }.joined(separator: " · "))
                        .textSelection(.enabled)
                }.font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .onTapGesture { open(.history) }
            .help("Open Git history")
        } else if inspecting {
            ProgressView("Reading the last commit…").controlSize(.small)
        }
    }

    // MARK: Activity and working tree

    private var activity: some View {
        Card(title: "Activity", systemImage: "chart.bar.xaxis", action: ("Insights", { open(.history) })) {
            if let git, !git.weeklyCommits.isEmpty {
                let total = git.weeklyCommits.reduce(0, +)
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Figure(value: total.formatted(), label: "commits in 12 weeks")
                    Figure(value: (git.weeklyCommits.last ?? 0).formatted(), label: "this week")
                    if let contributors = git.recentContributors { Figure(value: contributors.formatted(), label: contributors == 1 ? "author" : "authors") }
                }
                Chart(Array(git.weeklyCommits.enumerated()), id: \.offset) { week in
                    BarMark(x: .value("Week", String(week.offset)), y: .value("Commits", week.element), width: .ratio(0.7))
                        .foregroundStyle(week.offset == git.weeklyCommits.count - 1 ? Self.tint : Self.tint.opacity(0.45))
                        .cornerRadius(2)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height: 54)
                .accessibilityLabel("\(total) commits over the last twelve weeks")
                Text(total == 0 ? "No commits in the last twelve weeks." : "Weekly commits, oldest left, this week highlighted.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(inspecting ? "Reading…" : "Unavailable").foregroundStyle(.secondary)
            }
        }
    }

    private var workingTree: some View {
        Card(title: "Working tree", systemImage: "square.stack.3d.down.right", action: ("Files", { open(.files) })) {
            if let git {
                if git.isDirty {
                    let parts: [(String, Int, Color)] = [("Staged", git.staged, .green), ("Unstaged", git.unstaged, .orange),
                                                         ("Untracked", git.untracked, .blue), ("Conflicts", git.conflicted, .red)]
                    GeometryReader { proxy in
                        HStack(spacing: 2) {
                            ForEach(parts.filter { $0.1 > 0 }, id: \.0) { part in
                                RoundedRectangle(cornerRadius: 3).fill(part.2.opacity(0.8))
                                    .frame(width: max(6, (proxy.size.width - 6) * CGFloat(part.1) / CGFloat(git.changes)))
                            }
                        }
                    }.frame(height: 12)
                    FlowLayout(spacing: 12, lineSpacing: 6) {
                        ForEach(parts, id: \.0) { part in
                            HStack(spacing: 4) {
                                Circle().fill(part.2.opacity(part.1 > 0 ? 0.8 : 0.25)).frame(width: 8, height: 8)
                                Text("\(part.1) \(part.0.lowercased())").font(.callout).monospacedDigit()
                                    .foregroundStyle(part.1 > 0 ? .primary : .secondary)
                            }
                        }
                    }
                } else {
                    Label("Nothing to commit", systemImage: "checkmark.seal.fill").font(.title3.weight(.semibold)).foregroundStyle(.green)
                }
                Text(git.upstream.map { "Tracking \($0)." } ?? "No upstream branch is set.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(inspecting ? "Reading…" : "Unavailable").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Running now

    private var runningNow: some View {
        let running = containers.filter(\.isRunning)
        let live = sessions.filter { $0.endedAt == nil }
        return Card(title: "Running now", systemImage: "bolt.fill") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { serversTile; dockerTile(running); agentsTile(live) }
                VStack(alignment: .leading, spacing: 12) { serversTile; dockerTile(running); agentsTile(live) }
            }
        }
    }

    private var serversTile: some View {
        let endpoints = servers.flatMap { server in server.portPairs.map { (server: server, port: $0.primary) } }
        return Tile(title: "Dev servers", systemImage: "server.rack", color: AppRoute.devServers.tint,
                    value: servers.isEmpty ? "None" : "\(servers.count)", open: { open(.devServers) }) {
            ForEach(Array(endpoints.prefix(4).enumerated()), id: \.offset) { _, endpoint in
                if endpoint.port.mayServeHTTP, let url = endpoint.port.browserURL {
                    Link(destination: url) {
                        Label(url.absoluteString.replacingOccurrences(of: "http://", with: ""), systemImage: "arrow.up.forward.square")
                            .lineLimit(1).truncationMode(.middle)
                    }.help("\(endpoint.server.processName) · PID \(endpoint.server.process.pid)")
                } else {
                    Text("\(endpoint.port.protocolName) \(endpoint.port.localAddress) · \(endpoint.server.processName)")
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            if endpoints.count > 4 { Text("\(endpoints.count - 4) more ports").foregroundStyle(.secondary) }
        }
    }

    private func dockerTile(_ running: [DockerContainer]) -> some View {
        Tile(title: "Containers", systemImage: "shippingbox", color: AppRoute.docker.tint,
             value: containers.isEmpty ? "None" : "\(running.count) of \(containers.count)", open: { open(.docker) }) {
            ForEach(containers.sorted { $0.isRunning && !$1.isRunning }.prefix(4)) { container in
                HStack(spacing: 5) {
                    Circle().fill(container.isRunning ? .green : .secondary).frame(width: 6, height: 6)
                    Text(container.displayName).lineLimit(1)
                }
            }
            if containers.count > 4 { Text("\(containers.count - 4) more").foregroundStyle(.secondary) }
        }
    }

    private func agentsTile(_ live: [AgentSession]) -> some View {
        Tile(title: "AI agents", systemImage: "sparkles", color: AppRoute.agents.tint,
             value: live.isEmpty ? "None" : "\(live.count)", open: { open(.agents) }) {
            ForEach(live.prefix(4)) { session in
                HStack(spacing: 5) {
                    Circle().fill(session.activity.color).frame(width: 6, height: 6)
                    Text("\(session.agentName) · \(session.activity.title)").lineLimit(1)
                }
            }
        }
    }

    // MARK: Stack

    @ViewBuilder private var stack: some View {
        let manifests = manifests ?? []
        if !manifests.isEmpty || !project.runtimes.isEmpty {
            Card(title: "Stack", systemImage: "cube", action: ("Runtimes", { open(.runtimes) })) {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(manifests) { manifest in
                        StackChip(language: manifest.language, detail: manifest.requirement.map { "requires \($0)" } ?? manifest.file,
                                  file: manifest.file, status: matches?.first { $0.requirement.source == manifest.file }?.status)
                    }
                    // A pin that repeats a language file's requirement (a Gemfile `ruby` and `.ruby-version`) shows once.
                    ForEach(project.runtimes.filter { runtime in
                        runtime.name != "direnv" && !manifests.contains { $0.language == runtime.name && $0.requirement == runtime.version }
                    }) { runtime in
                        StackChip(language: runtime.name, detail: runtime.version ?? (runtime.isEnvironment ? "virtual environment" : "pinned"),
                                  file: runtime.marker,
                                  status: matches?.first { $0.requirement.source == runtime.marker && $0.requirement.language.rawValue == runtime.name }?.status)
                    }
                }
                if matches == nil {
                    Text("Install status appears once Development environments discovery has run.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if manifests == nil && inspecting {
            ProgressView("Reading language files…").controlSize(.small)
        }
    }

    // MARK: Details

    private var details: some View {
        Card(title: "Details", systemImage: "info.circle") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Location", project.root, monospaced: true)
                row("Commit", project.git?.commit ?? "Unavailable", monospaced: true)
                if let remote = report?.remoteURL { row("Remote", remote, monospaced: true) }
                row("Modified", project.modifiedAt.map { Formatting.dated($0.formatted(date: .abbreviated, time: .shortened), $0) } ?? "Unavailable")
                row("Size", size.map(Formatting.bytes) ?? "Not measured")
            }
        }
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label).font(.callout).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).font(monospaced ? .callout.monospaced() : .callout).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle).help(value)
        }
    }
}

// MARK: - Building blocks

private struct Pill: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout.weight(.medium)).lineLimit(1)
            .foregroundStyle(color == .secondary ? Color.secondary : color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.13), in: Capsule())
    }
}

private struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    var action: (String, () -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage).font(.headline)
                Spacer()
                if let action { Button(action.0, action: action.1).buttonStyle(.link).font(.callout) }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct Figure: View {
    let value: String
    let label: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct Tile<Content: View>: View {
    let title: String
    let systemImage: String
    let color: Color
    let value: String
    var open: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: open) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage).foregroundStyle(color)
                    Text(title).font(.callout.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(value).font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(value == "None" ? .secondary : .primary)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) { content }.font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .opacity(value == "None" ? 0.7 : 1)
    }
}

private struct StackChip: View {
    let language: String
    let detail: String
    let file: String
    let status: ProjectRuntimeMatch.Status?

    var body: some View {
        HStack(spacing: 6) {
            if let status {
                Image(systemName: icon(status)).foregroundStyle(color(status))
            }
            Text(language).font(.callout.weight(.semibold))
            Text(detail).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .help(file + (status.map { " · " + label($0) } ?? ""))
    }

    private func icon(_ status: ProjectRuntimeMatch.Status) -> String {
        switch status {
        case .installed: "checkmark.circle.fill"
        case .mismatch: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        case .notFound: "xmark.circle.fill"
        }
    }

    private func color(_ status: ProjectRuntimeMatch.Status) -> Color {
        switch status {
        case .installed: .green
        case .mismatch: .orange
        case .unknown: .secondary
        case .notFound: .red
        }
    }

    private func label(_ status: ProjectRuntimeMatch.Status) -> String {
        switch status {
        case .installed: "Installed"
        case .mismatch: "Version not installed"
        case .unknown: "Installed, version unknown"
        case .notFound: "Not installed"
        }
    }
}
