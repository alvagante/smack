import Foundation
import CoreServices
import Darwin

// Probe FSEvents registration and delivery only. Production rescan/enrichment cost is separate.
final class Counters {
    var callbacks = 0
    var events = 0
    var dropped = 0
    var firstSynthetic: Double?
    var lastCallback: Double?
    var syntheticFiles: Set<String> = []
}
func usage() -> (Double, Int64) {
    var value = rusage()
    getrusage(RUSAGE_SELF, &value)
    let cpu = Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
        + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    return (cpu, Int64(value.ru_maxrss))
}
let mode = CommandLine.arguments[1]
let seconds = Double(CommandLine.arguments[2])!
let synthetic = CommandLine.arguments[3]
let home = FileManager.default.homeDirectoryForCurrentUser.path
let paths = [home + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons",
             home + "/.ssh/authorized_keys", home + "/.ssh/rc", home + "/.zshrc", home + "/.zprofile",
             home + "/.zshenv", home + "/.bash_profile", home + "/.bashrc", home + "/.profile",
             home + "/.config/fish/config.fish", "/etc/hosts", "/etc/sudoers.d",
             "/Library/Preferences/com.apple.loginwindow.plist", synthetic]
let counters = Counters()
var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(counters).toOpaque(), retain: nil, release: nil, copyDescription: nil)
var stream: FSEventStreamRef?
if mode == "watch" {
    stream = FSEventStreamCreate(nil, { _, info, count, rawPaths, flags, _ in
        let state = Unmanaged<Counters>.fromOpaque(info!).takeUnretainedValue()
        state.callbacks += 1
        state.events += count
        let eventPaths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as! [String]
        for path in eventPaths where path.hasSuffix(".plist") && path.contains("events-burst") {
            state.syntheticFiles.insert(path)
        }
        for i in 0..<count {
            if flags[i] & UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagMustScanSubDirs) != 0 { state.dropped += 1 }
        }
        state.firstSynthetic = state.firstSynthetic ?? ProcessInfo.processInfo.systemUptime
        state.lastCallback = ProcessInfo.processInfo.systemUptime
    }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2,
    UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
    guard let stream else { fatalError("stream creation failed") }
    FSEventStreamSetDispatchQueue(stream, .main)
    guard FSEventStreamStart(stream) else { fatalError("stream start failed") }
}
let started = ProcessInfo.processInfo.systemUptime
let initial = usage()
print("started mode=\(mode) pid=\(getpid()) registered=\(mode == "watch" ? paths.count : 0) existing=\(paths.filter { FileManager.default.fileExists(atPath: $0) }.count)")
fflush(stdout)
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    let final = usage()
    let elapsed = ProcessInfo.processInfo.systemUptime - started
    let result: [String: Any] = ["mode": mode, "started_uptime": started, "synthetic_unique_files": counters.syntheticFiles.count, "elapsed_s": elapsed, "cpu_s": final.0 - initial.0,
        "cpu_percent_one_core": 100 * (final.0 - initial.0) / elapsed,
        "maxrss_start_bytes": initial.1, "maxrss_end_bytes": final.1,
        "callbacks": counters.callbacks, "events": counters.events, "rescan_flags": counters.dropped,
        "first_callback_s": counters.firstSynthetic.map { $0 - started } ?? -1,
        "last_callback_s": counters.lastCallback.map { $0 - started } ?? -1]
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    exit(0)
}
dispatchMain()
