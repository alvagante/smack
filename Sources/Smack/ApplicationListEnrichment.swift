import Foundation

/// Code signatures of the executables the Applications list shows. Read only for rows that appear, off the main
/// thread and in batches so the list redraws once per batch, then kept by path: a running executable's signature
/// does not change under it.
@MainActor
final class ApplicationListEnrichment: ObservableObject {
    static let batchSize = 16
    /// Distinct executables kept; the cache starts over past it rather than tracking age.
    static let capacity = 2_000

    @Published private(set) var signatures: [String: CodeSignatureInfo] = [:]
    private var queue: [String] = []
    private var requested: Set<String> = []
    private var worker: Task<Void, Never>?
    private let reader: @Sendable (String) -> CodeSignatureInfo

    init(reader: @escaping @Sendable (String) -> CodeSignatureInfo = ProcessProvenanceResolver.signature(path:)) {
        self.reader = reader
    }

    func requestSignature(path: String) {
        guard path.hasPrefix("/"), !requested.contains(path) else { return }
        if requested.count >= Self.capacity {
            requested.removeAll()
            signatures.removeAll()
        }
        requested.insert(path)
        queue.append(path)
        guard worker == nil else { return }
        let reader = reader
        worker = Task { [weak self] in
            while let self, !self.queue.isEmpty {
                let batch = Array(self.queue.prefix(Self.batchSize))
                self.queue.removeFirst(batch.count)
                let read = await Task.detached(priority: .utility) {
                    batch.map { ($0, reader($0)) }
                }.value
                for (path, info) in read { self.signatures[path] = info }
            }
            self?.worker = nil
        }
    }

    /// Waits for queued reads; for tests.
    func drain() async { await worker?.value }
}
