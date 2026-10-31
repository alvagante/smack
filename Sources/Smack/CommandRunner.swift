import Foundation
import SmackIPC

/// Fixed executables and explicit arguments; shared lifecycle handling also protects helper traces.
enum CommandRunner {
    typealias Result = Subprocess.Result

    /// Mutations finish even if their view disappears. Read-only probes honor task cancellation.
    static func run(_ executable: String, _ arguments: [String], input: String? = nil,
                    timeout: TimeInterval? = nil, outputLimit: Int = .max,
                    cancellable: Bool = true) async -> Result {
#if SMACK_APP_STORE
        .unavailable("Unavailable in the App Store build.")
#else
        await Subprocess.run(executable, arguments, input: input, timeout: timeout,
                             outputLimit: outputLimit, cancellable: cancellable)
#endif
    }
}
