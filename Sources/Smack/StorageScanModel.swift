import Foundation
import Combine
import SmackIPC

enum StorageScanScope: String, CaseIterable, Identifiable {
    case home = "Home"
    case disk = "Full Disk"
    var id: Self { self }
}

@MainActor
final class StorageScanModel: ObservableObject {
    @Published var showSetup = false
    @Published var hovered: String?
    @Published private(set) var helperReady = false
    @Published var scope: StorageScanScope = .home
    @Published var useAdministrator = false
    @Published private(set) var isScanning = false
    @Published private(set) var progress: StorageScanSnapshot?
    @Published private(set) var result: StorageScanSnapshot?
    @Published private(set) var completedAt: Date?
    @Published private(set) var error: String?
    @Published private(set) var trail: [String] = []
    @Published private(set) var current: StorageDirectory?
    @Published private(set) var currentChildren: [StorageDirectory] = []
    private var task: Task<Void, Never>?
    private var localJob: StorageScanJob?
    private let client = PrivilegedSamplingClient()
    private var privilegedJob = false
    private var cancelRequested = false
    private var helperSubscription: AnyCancellable?

    init(helper: PrivilegedSamplingController? = nil) {
        // Subscribe once: recreating a current-value publisher while rendering feeds changes
        // back into SwiftUI, even when the reported helper state has not changed.
        helperSubscription = helper?.$state.map { state in
            if case .running = state { return true }
            return false
        }
        .removeDuplicates()
        .sink { [weak self] ready in
            guard let self, self.helperReady != ready else { return }
            self.helperReady = ready
        }
    }

    func open(_ path: String) {
        guard let tree = result?.tree, let index = tree.index(for: path) else { return }
        current = tree.directory(at: index)
        currentChildren = tree.children(of: index).sorted {
            let lhs = tree.nodes[$0], rhs = tree.nodes[$1]
            return lhs.bytes == rhs.bytes ? lhs.name < rhs.name : lhs.bytes > rhs.bytes
        }.map { tree.directory(at: $0) }
        var ancestors: [String] = []
        var ancestor = index
        while ancestor >= 0 {
            ancestors.append(tree.path(at: ancestor))
            ancestor = tree.nodes[ancestor].parent
        }
        trail = ancestors.reversed()
        hovered = nil
    }

    func clearResults() {
        guard !isScanning else { return }
        result = nil
        progress = nil
        current = nil
        currentChildren = []
        trail = []
        completedAt = nil
        hovered = nil
        error = nil
    }

    func scan(root: URL) {
        guard !isScanning else { return }
        isScanning = true
        cancelRequested = false
        progress = nil
        error = nil
        privilegedJob = scope == .disk && useAdministrator
        let scopedAccess = root.startAccessingSecurityScopedResource()
        task = Task {
            defer { if scopedAccess { root.stopAccessingSecurityScopedResource() } }
            if privilegedJob {
                client.setAvailable(true)
                guard await client.startStorageScan() == true else {
                    error = "The helper could not start the scan. Update or enable it in Superuser Setup."
                    isScanning = false
                    return
                }
            } else {
                let job = StorageScanJob(root: root.path)
                localJob = job
                if cancelRequested { job.cancel() }
                Task.detached(priority: .utility) { job.run() }
            }
            while !Task.isCancelled {
                if cancelRequested && privilegedJob { await client.cancelStorageScan() }
                let status: StorageScanSnapshot?
                if privilegedJob { status = await client.storageScanStatus() }
                else { status = localJob?.status() }
                guard let status else {
                    error = privilegedJob
                        ? "The helper could not return the scan. Update the helper in Superuser Setup, then try again."
                        : "The scan connection was lost. Try scanning again."
                    if privilegedJob { await client.cancelStorageScan() }
                    break
                }
                if status.finished {
                    var summary = status
                    summary.tree = StorageTree(root: status.root)
                    progress = summary
                    if let message = status.error { error = message }
                    else if !status.cancelled {
                        completedAt = Date()
                        result = status
                        open(status.root)
                    }
                    break
                }
                progress = status
                try? await Task.sleep(for: .milliseconds(300))
            }
            localJob = nil
            task = nil
            isScanning = false
        }
    }

    func cancel() {
        cancelRequested = true
        localJob?.cancel()
    }
}
