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
    private var directories: [String: StorageDirectory] = [:]
    private var children: [String: [StorageDirectory]] = [:]
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

    var current: StorageDirectory? { trail.last.flatMap { directories[$0] } }
    var currentChildren: [StorageDirectory] { trail.last.flatMap { children[$0] } ?? [] }

    func open(_ path: String) {
        guard directories[path] != nil else { return }
        if let index = trail.firstIndex(of: path) { trail = Array(trail.prefix(index + 1)) }
        else { trail.append(path) }
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
                    error = "The scan connection was lost. Try scanning again."
                    if privilegedJob { await client.cancelStorageScan() }
                    break
                }
                progress = status
                if status.finished {
                    if let message = status.error { error = message }
                    else if !status.cancelled {
                        completedAt = Date()
                        result = status
                        directories = Dictionary(uniqueKeysWithValues: status.directories.map { ($0.path, $0) })
                        children = Dictionary(grouping: status.directories.filter { $0.parent != nil }, by: { $0.parent! })
                            .mapValues { $0.sorted { $0.bytes == $1.bytes ? $0.path < $1.path : $0.bytes > $1.bytes } }
                        trail = [status.root]
                    }
                    break
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            localJob = nil
            isScanning = false
        }
    }

    func cancel() {
        cancelRequested = true
        localJob?.cancel()
    }
}
