import Combine
import Foundation

/// On-demand inspection of one process or application: live inventory, provenance and the Gatekeeper check.
@MainActor
final class ProcessInspectionModel: ObservableObject {
    @Published private(set) var inventory: ProcessInventory?
    @Published private(set) var inventoryLoading = false
    /// Inventories of all processes of one application, merged; separate from the single-process `inventory`.
    @Published private(set) var applicationInventory: ApplicationInventory?
    @Published private(set) var applicationInventoryLoading = false
    @Published private(set) var provenance: ProcessProvenance?
    @Published private(set) var gatekeeperResult: String?
    @Published private(set) var gatekeeperRunning = false

    /// Large applications (browsers) can have thousands of processes; only the biggest are inspected.
    static let applicationInventoryProcessLimit = 40

    private let collectInventory: @Sendable (ProcessMetrics) async -> ProcessInventory
    private let knowledgeBase: ProcessKnowledgeBase
    private let fileFacts = ProcessFileFactsCache()
    private var launchdCache: (timestamp: Date, index: [String: LaunchdMatch])?
    private var scheduledInventories: [String: ProcessInventory] = [:]
    private var inventoryTask: Task<Void, Never>?
    private var provenanceTask: Task<Void, Never>?
    private var applicationInventoryGeneration = 0

    init(knowledgeBase: ProcessKnowledgeBase = .shared,
         collectInventory: @escaping @Sendable (ProcessMetrics) async -> ProcessInventory) {
        self.knowledgeBase = knowledgeBase
        self.collectInventory = collectInventory
    }

    /// Background inventories, served first while a fresh one loads. Callers pass only running processes.
    func receiveScheduled(_ inventory: ProcessInventory, for id: String) {
        scheduledInventories[id] = inventory
    }

    func retainScheduled(_ liveIDs: Set<String>) {
        scheduledInventories = scheduledInventories.filter { liveIDs.contains($0.key) }
    }

    func loadInventory(for process: ProcessMetrics) {
        inventoryTask?.cancel()
        inventory = scheduledInventories[process.id]
        inventoryLoading = true
        inventoryTask = Task {
            let result = await collectInventory(process)
            guard !Task.isCancelled else { return }
            inventory = result
            inventoryLoading = false
        }
    }

    /// Inspects the application's largest processes one at a time, publishing the merged result as it grows.
    /// Run from `.task(id:)` so leaving the page cancels it. `refresh` skips scheduled inventories.
    func loadApplicationInventory(for application: ApplicationMetrics, refresh: Bool) async {
        applicationInventoryGeneration += 1
        let generation = applicationInventoryGeneration
        applicationInventory = nil
        applicationInventoryLoading = true
        defer { if generation == applicationInventoryGeneration { applicationInventoryLoading = false } }

        let selected = Array(application.processes.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(Self.applicationInventoryProcessLimit))
        var collected: [(process: ProcessRef, inventory: ProcessInventory)] = []
        for (index, process) in selected.enumerated() {
            guard !Task.isCancelled else { return }
            let inventory: ProcessInventory
            if !refresh, let cached = scheduledInventories[process.id] {
                inventory = cached
            } else {
                inventory = await collectInventory(process)
            }
            guard !Task.isCancelled, generation == applicationInventoryGeneration else { return }
            collected.append((ProcessRef(process), inventory))
            if index % 4 == 3 || index == selected.count - 1 {
                applicationInventory = ApplicationInventory.aggregate(collected, total: application.processes.count)
            }
        }
    }

    /// Ancestry, origin and knowledge come from the snapshot at once; signature, architecture and quarantine are read
    /// on demand through a bounded cache.
    func loadProvenance(for process: ProcessMetrics, in snapshot: ProcessSnapshot?, startup: StartupInventory?) {
        provenanceTask?.cancel()
        gatekeeperResult = nil
        let all = Self.processesByPID(snapshot)
        let index = launchdIndex(from: startup)
        let knowledge = knowledgeBase
        provenance = ProcessProvenanceResolver.resolve(
            process: process, processes: all, launchdIndex: index, knowledge: knowledge, facts: nil, translated: nil
        )
        let path = process.executablePath
        let pid = process.identity.pid
        provenanceTask = Task {
            let facts: ProcessFileFacts?
            if let path { facts = await fileFacts.facts(for: path) } else { facts = nil }
            guard !Task.isCancelled else { return }
            provenance = ProcessProvenanceResolver.resolve(
                process: process, processes: all, launchdIndex: index, knowledge: knowledge,
                facts: facts, translated: ProcessProvenanceResolver.isTranslated(pid: pid)
            )
        }
    }

    func checkGatekeeper(path: String) {
        guard Capabilities.supportsGatekeeperCheck, !gatekeeperRunning else { return }
        gatekeeperRunning = true
        Task {
            let result = await GatekeeperCheck.assess(path: path)
            gatekeeperResult = result
            gatekeeperRunning = false
        }
    }

    /// One dictionary per startup inventory, never per process.
    func launchdIndex(from inventory: StartupInventory?) -> [String: LaunchdMatch] {
        guard let inventory else { return [:] }
        if let launchdCache, launchdCache.timestamp == inventory.timestamp { return launchdCache.index }
        let index = ProcessProvenanceResolver.launchdIndex(from: inventory)
        launchdCache = (inventory.timestamp, index)
        return index
    }

    private static func processesByPID(_ snapshot: ProcessSnapshot?) -> [Int32: ProcessMetrics] {
        var result: [Int32: ProcessMetrics] = [:]
        for process in (snapshot?.applications ?? []).flatMap(\.processes) + (snapshot?.backgroundProcesses ?? []) {
            result[process.identity.pid] = process
        }
        return result
    }
}
