import Foundation

enum BackgroundWork {
    /// Runs blocking file or parsing work off the main actor and cancels it when the caller is cancelled,
    /// so a closed Page stops the work instead of letting it finish unseen.
    static func run<T: Sendable>(priority: TaskPriority = .utility, _ work: @escaping @Sendable () -> T) async -> T {
        let task = Task.detached(priority: priority, operation: work)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}
