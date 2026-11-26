import Foundation

enum SavedSessionSort: String, CaseIterable, Identifiable {
    case title = "Session"
    case activity = "Last activity", agent = "Agent", project = "Project", duration = "Duration"
    case input = "Tokens in", output = "Tokens out"
    var id: Self { self }
    var startsAscending: Bool { self == .title || self == .agent || self == .project }
}

enum SavedSessionList {
    static func items(_ items: [PastTranscript], query: String, agents: Set<String>,
                      sort: SavedSessionSort, ascending: Bool) -> [PastTranscript] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            (agents.isEmpty || agents.contains(item.agentID)) && (text.isEmpty ||
                [item.title, item.directory, item.agentID,
                 item.agentName]
                    .compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(text) })
        }.sorted { a, b in
            let order: ComparisonResult
            switch sort {
            case .title: order = (a.title ?? "Untitled session").localizedStandardCompare(b.title ?? "Untitled session")
            case .activity: order = a.updated.compare(b.updated)
            case .agent: order = a.agentName.localizedStandardCompare(b.agentName)
            case .project: order = (a.projectName ?? "").localizedStandardCompare(b.projectName ?? "")
            case .duration, .input, .output:
                let lhs = sort == .duration ? a.duration : (sort == .input ? a.inputTokens : a.outputTokens).map(Double.init)
                let rhs = sort == .duration ? b.duration : (sort == .input ? b.inputTokens : b.outputTokens).map(Double.init)
                if lhs == nil || rhs == nil {
                    if lhs == nil && rhs == nil { return a.id < b.id }
                    return lhs != nil
                }
                order = lhs! < rhs! ? .orderedAscending : lhs! > rhs! ? .orderedDescending : .orderedSame
            }
            if order == .orderedSame { return a.id < b.id }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}

struct SavedSessionSummary {
    let projects: Int
    let agents: Int
    let knownTokens: Int?
    let tokenSessions: Int

    init(items: [PastTranscript]) {
        projects = Set(items.compactMap(\.directory)).count
        agents = Set(items.map(\.agentID)).count
        let totals = items.compactMap { item -> Int? in
            guard let input = item.inputTokens, let output = item.outputTokens else { return nil }
            return input + output
        }
        tokenSessions = totals.count
        knownTokens = totals.isEmpty ? nil : totals.reduce(0, +)
    }
}
