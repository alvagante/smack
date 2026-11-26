import Foundation

enum AgentSessionActivity: Sendable {
    case working, idle, ended

    /// Tree CPU at or above this counts as working; an idle agent waiting for input stays well below it.
    static let workingCPU = 5.0
}

extension AgentSession {
    var activity: AgentSessionActivity {
        if endedAt != nil { return .ended }
        return totals.cpu >= AgentSessionActivity.workingCPU ? .working : .idle
    }
}

struct AgentSessionPoint: Sendable {
    var timestamp: Date
    var cpu: Double
    var memory: Double
    var disk: Double
    var network: Double?
}

/// Recent totals per Agent Session, kept in memory only, so session charts need no extra collection.
/// Bounded by `capacity` per session; a session's points go when the tracker stops reporting it.
struct AgentSessionHistory {
    let capacity: Int
    private var values: [String: [AgentSessionPoint]] = [:]

    init(capacity: Int = 120) { self.capacity = max(1, capacity) }

    func points(for id: String) -> [AgentSessionPoint] { values[id] ?? [] }

    mutating func record(_ sessions: [AgentSession], at date: Date) {
        let ids = Set(sessions.map(\.id))
        values = values.filter { ids.contains($0.key) }
        for session in sessions where session.endedAt == nil {
            if let last = values[session.id]?.last, last.timestamp >= date { continue }
            let totals = session.totals
            let network = totals.networkReceive.map { $0 + (totals.networkSend ?? 0) }
            values[session.id, default: []].append(AgentSessionPoint(timestamp: date, cpu: totals.cpu,
                memory: Double(totals.memory), disk: totals.diskRead + totals.diskWrite, network: network))
            let excess = values[session.id, default: []].count - capacity
            if excess > 0 { values[session.id, default: []].removeFirst(excess) }
        }
    }
}

/// Live sessions first, newest first, each followed by its nested sessions; ended sessions apart.
struct AgentSessionList {
    struct Entry: Identifiable {
        let session: AgentSession
        let depth: Int
        var id: String { session.id }
    }

    let live: [Entry]
    let ended: [AgentSession]

    init(sessions: [AgentSession]) {
        let newestFirst = sessions.sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt > $1.startedAt }
        let running = newestFirst.filter { $0.endedAt == nil }
        let runningIDs = Set(running.map(\.id))
        let children = Dictionary(grouping: running.filter { $0.parentSession.map(runningIDs.contains) ?? false },
                                  by: { $0.parentSession! })
        var entries: [Entry] = []
        var visited: Set<String> = []
        func add(_ session: AgentSession, depth: Int) {
            guard visited.insert(session.id).inserted else { return }
            entries.append(Entry(session: session, depth: depth))
            // Children read top-down in the order they started.
            for child in (children[session.id] ?? []).reversed() { add(child, depth: depth + 1) }
        }
        for session in running where !(session.parentSession.map(runningIDs.contains) ?? false) { add(session, depth: 0) }
        // A parent cycle has no top-level member; list what is left rather than hide it.
        for session in running { add(session, depth: 0) }
        live = entries
        ended = newestFirst.filter { $0.endedAt != nil }
    }
}

/// The part of `AgentMonitor` that changes on every process sample, observed only by the session views,
/// so the agent browser and its file preview do not redraw at the Live Refresh rate.
@MainActor
final class AgentSessionsModel: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var history = AgentSessionHistory()

    var liveCount: Int { sessions.lazy.filter { $0.endedAt == nil }.count }

    func receive(_ sessions: [AgentSession], at date: Date) {
        history.record(sessions, at: date)
        self.sessions = sessions
    }
}
