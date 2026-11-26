import Foundation
import SmackIPC
import Darwin

/// Fixed read-only sections run in a child so blocking filesystem and Security framework calls can be killed.
enum BaselineWorker {
    static var isRunning: Bool {
        CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--baseline-section"
    }

    struct Request: Codable {
        var id: String
        var settings: CollectionSettings
        var ports: [ListeningPort]?
        var timestamp: Date?
        var warning: String?
        var profiles: String?
        var backgroundTasks: String?

        init(_ collector: MachineBaselineCollector) {
            id = collector.id; settings = collector.settings
            ports = collector.listeners?.ports; timestamp = collector.listeners?.timestamp
            warning = collector.listeners?.warning
            profiles = collector.profiles; backgroundTasks = collector.backgroundTasks
        }
        var collector: MachineBaselineCollector {
            MachineBaselineCollector(id: id, settings: settings,
                listeners: timestamp.map { NetworkPortSnapshot(timestamp: $0, ports: ports ?? [], connections: [], warning: warning) },
                profiles: profiles, backgroundTasks: backgroundTasks)
        }
    }

    static func collect(_ collector: MachineBaselineCollector, executable: String, deadline: Duration) async -> BaselineSection {
        do {
            let data = try JSONEncoder().encode(Request(collector))
            guard data.count <= BaselineDocument.sizeLimit else { throw BaselineError("Section request exceeds 32 MiB") }
            let duration = deadline.components
            let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            let result = await Subprocess.run(executable, ["--baseline-section"],
                input: String(decoding: data, as: UTF8.self), timeout: seconds, outputLimit: BaselineDocument.sizeLimit, processGroup: .supervised)
            if result.cancelled { return .init(status: .incomplete, error: "Cancelled") }
            if result.timedOut { return .init(status: .incomplete, error: "Section timed out") }
            guard result.status == 0, !result.truncated,
                  let section = try BaselineDocument.decode(Data(result.output.utf8)).sections[collector.id] else {
                throw BaselineError("Section worker failed")
            }
            return section
        } catch { return .init(status: .incomplete, error: error.localizedDescription) }
    }

    static func run() async -> Int32 {
        let parentWatch = exitWithParent()
        defer { parentWatch.cancel() }
        do {
            var data = Data()
            while data.count <= BaselineDocument.sizeLimit {
                let chunk = try FileHandle.standardInput.read(upToCount: min(65_536, BaselineDocument.sizeLimit + 1 - data.count)) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            guard data.count <= BaselineDocument.sizeLimit else { return 1 }
            let request = try JSONDecoder().decode(Request.self, from: data)
            guard BaselineDiff.rules[request.id] != nil else { return 1 }
            let section = await request.collector.collectLocally()
            let document = BaselineDocument(sections: [request.id: section])
            FileHandle.standardOutput.write(try document.encoded())
            return 0
        } catch { return 1 }
    }

    /// The parent enforces the section deadline; once it is gone, nothing would stop a stuck section.
    private static func exitWithParent() -> any DispatchSourceProcess {
        let parent = getppid()
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { terminate() }
        source.resume()
        // The parent may have exited before the source was registered.
        if getppid() != parent { terminate() }
        return source
    }

    private static func terminate() -> Never {
        // Section commands share the worker's group. Signal it only as leader, never a shell's group.
        if getpgrp() == getpid() { _ = kill(0, SIGKILL) }
        // A thread may be stuck in a blocking call; exit handlers could deadlock on its locks.
        _exit(1)
    }
}
