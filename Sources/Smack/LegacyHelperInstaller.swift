import Foundation
import SmackIPC

enum HelperScriptAction: String, Sendable {
    case install
    case uninstall
}

enum HelperScriptResult: Equatable, Sendable {
    case completed
    case cancelled
    case failed(String)
}

#if SMACK_APP_STORE
/// The App Store build has no helper; this stub keeps the controller free of conditional code.
enum LegacyHelperInstaller {
    static var isInstalled: Bool { false }
    static var isCurrent: Bool { false }
    static func terminalCommand(for action: HelperScriptAction) -> String { "" }
    static func run(_ action: HelperScriptAction) async -> HelperScriptResult { .failed("Unavailable in the App Store build.") }
}
#else
/// Installs the helper as a classic launch daemon for builds without Developer ID, where
/// SMAppService refuses to register a daemon. The bundled script does the work as root; this
/// type only asks macOS for an administrator password and runs it.
enum LegacyHelperInstaller {
    private static var scriptPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/install-helper.sh").path
    }

    private static var bundledHelperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SmackHelper").path
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: SmackIPC.installedHelperPath)
            || FileManager.default.fileExists(atPath: SmackIPC.installedPlistPath)
    }

    /// Compares code, not files: re-signing identical code does not count as an update.
    static var isCurrent: Bool {
        guard let installed = SigningIdentity.codeDirectoryHash(atPath: SmackIPC.installedHelperPath),
              let bundled = SigningIdentity.codeDirectoryHash(atPath: bundledHelperPath) else {
            return false
        }
        return installed == bundled
    }

    static func terminalCommand(for action: HelperScriptAction) -> String {
        switch action {
        case .install:
            return "sudo \(shellQuoted(scriptPath)) install \(shellQuoted(Bundle.main.bundleURL.path))"
        case .uninstall:
            return "sudo \(shellQuoted(scriptPath)) uninstall"
        }
    }

    /// Shows the standard administrator prompt. Paths travel as AppleScript arguments and are
    /// quoted by `quoted form of`, never interpolated into the script source.
    static func run(_ action: HelperScriptAction) async -> HelperScriptResult {
        let prompt = action == .install
            ? "Smack wants to install its superuser sampling helper."
            : "Smack wants to remove its superuser sampling helper."
        let source = [
            "on run argv",
            "do shell script (quoted form of item 1 of argv) & \" \" & (quoted form of item 2 of argv) & \" \" & (quoted form of item 3 of argv) with prompt \(appleScriptString(prompt)) with administrator privileges",
            "end run"
        ]
        var arguments = source.flatMap { ["-e", $0] }
        arguments += [scriptPath, action.rawValue, Bundle.main.bundleURL.path]

        return await withCheckedContinuation { continuation in
            let process = Process()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            process.terminationHandler = { process in
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: result(status: process.terminationStatus, message: message))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: .failed(error.localizedDescription))
            }
        }
    }

    static func result(status: Int32, message: String) -> HelperScriptResult {
        if status == 0 { return .completed }
        // AppleScript reports a dismissed password prompt as error -128.
        if message.contains("(-128)") { return .cancelled }
        return .failed(message.isEmpty ? "The helper script exited with status \(status)." : message)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
#endif
