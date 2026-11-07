import SwiftUI

struct ProjectFilesView: View {
    let root: String
    @StateObject private var browser = UserHomeMonitor()

    var body: some View {
        UserHomeDetailView(model: browser, rootDirectory: URL(fileURLWithPath: root))
    }
}

struct ProjectHistoryView: View {
    let root: String
    var inspector = ProjectHistoryInspector()
    @State private var history: ProjectHistory?
    @State private var selected: String?
    @State private var detail: String?
    @State private var refresh = 0
    @AppStorage(FileContentsScrollView<EmptyView>.wrapKey) private var wrap = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailContentTitle(title: "Git history", systemImage: "clock.arrow.circlepath", color: AppRoute.projects.tint,
                               caption: "Latest 100 commits on the current branch. Local data, refreshed on request.") {
                RefreshButton { selected = nil; detail = nil; refresh += 1 }
            }
            if let history {
                ForEach(Array(history.messages.enumerated()), id: \.offset) { _, message in
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                DisclosureGroup("Branches and tags (up to 200)") {
                    metadata(history.references, empty: "No branches or tags")
                }
                DisclosureGroup("Remotes") {
                    metadata(history.remotes, empty: "No remotes configured")
                }
                if history.commits.isEmpty {
                    ContentUnavailableView("No commits available", systemImage: "clock")
                } else {
                    List(selection: $selected) {
                        ForEach(history.commits) { commit in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(String(commit.id.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(commit.subject).font(.callout.weight(.medium)).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                HStack(spacing: 8) {
                                    Text(commit.author)
                                    Text(Formatting.dated(commit.date.formatted(date: .abbreviated, time: .shortened), commit.date))
                                    if !commit.references.isEmpty { Text(commit.references).foregroundStyle(AppRoute.projects.tint) }
                                }
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .tag(commit.id)
                            .help(commit.subject + "\n" + commit.id)
                        }
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 120, idealHeight: 200, maxHeight: 240)
                }
                Divider()
                HStack {
                    Text("Commit details and patch").font(.headline)
                    Spacer()
                    WrapToggle(wrap: $wrap)
                }
                FileContentsScrollView(wrap: wrap) {
                    Group {
                        if selected == nil {
                            Text("Select a commit to view its message, changed files and patch.").foregroundStyle(.secondary)
                        } else if let detail {
                            Text(detail).font(.caption.monospaced()).textSelection(.enabled)
                                .fixedSize(horizontal: !wrap, vertical: true)
                        } else {
                            ProgressView("Reading commit…")
                        }
                    }.padding(8)
                }
                .frame(minHeight: 140, maxHeight: .infinity)
            } else {
                ProgressView("Reading local Git history…")
                Spacer()
            }
        }
        .task(id: refresh) {
            history = nil
            let value = await inspector.history(root: root)
            guard !Task.isCancelled else { return }
            history = value
        }
        .task(id: selected) {
            detail = nil
            guard let selected else { return }
            let value = await inspector.commit(root: root, id: selected)
            guard !Task.isCancelled else { return }
            detail = value
        }
    }

    private func metadata(_ text: String, empty: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text.isEmpty ? empty : text)
                .font(.caption.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 100)
    }
}
