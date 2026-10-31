import AppKit
import Foundation
import SmackIPC
import SwiftUI
import Testing
@testable import Smack

private func argumentBuffer(_ arguments: [String], environment: [String] = []) -> Data {
    var count = Int32(arguments.count)
    var data = withUnsafeBytes(of: &count) { Data($0) }
    data.append(contentsOf: Array("/bin/example".utf8) + [0, 0, 0])
    for value in arguments + environment { data.append(contentsOf: Array(value.utf8) + [0]) }
    data.append(0)
    return data
}

@Test func inspectionArgumentsPreserveEmptyAndSpacedValuesAndMaskCredentials() throws {
    let context = try #require(ProcessInspection.parseArguments(argumentBuffer(
        ["/bin/example", "", "two words", "--token", "sensitive", "--password=hidden", "--port", "8080"],
        environment: ["PATH=/bin", "UNEXPECTED_CREDENTIAL=hidden", "EMPTY=", "VALUE=a=b"]
    )))
    #expect(context.arguments == ["/bin/example", "", "two words", "--token", "••••", "--password=••••", "--port", "8080"])
    #expect(context.environment.map(\.label) == ["EMPTY", "PATH", "UNEXPECTED_CREDENTIAL", "VALUE"])
    #expect(context.environment.first { $0.label == "EMPTY" }?.value == "(empty)")
    #expect(context.environment.filter { $0.label != "EMPTY" }.allSatisfy { $0.value == "••••" })
}

@Test func inspectionRejectsTruncatedAndInvalidArgumentBuffers() {
    #expect(ProcessInspection.parseArguments(Data()) == nil)
    #expect(ProcessInspection.parseArguments(Data([255, 255, 255, 255])) == nil)
    var data = argumentBuffer(["example", "second"])
    data.removeLast(4)
    #expect(ProcessInspection.parseArguments(data) == nil)
}

@Test func inspectionLogsClampToTheProcessLifetimeAndApplySeverity() {
    let identity = ProcessIdentity(pid: 123, startTime: Date(timeIntervalSince1970: 200))
    let arguments = ProcessInspection.logArguments(identity: identity, since: Date(timeIntervalSince1970: 100), severity: "Errors")
    #expect(arguments.contains("@200"))
    #expect(arguments.contains("processID == 123 AND (messageType == error OR messageType == fault)"))
    #expect(!ProcessInspection.logArguments(identity: identity, since: Date(timeIntervalSince1970: 300), severity: "All").joined().contains("messageType =="))
}

@Test func inspectionLogParsingSkipsMetadataAndMalformedRowsAndFiltersMessages() {
    let text = """
    Filtering the log data...
    {"timestamp":"2026-10-30 10:00:00","messageType":"Error","eventMessage":"Failed to connect"}
    {"timestamp":"2026-10-30 10:00:01","messageType":"Default","eventMessage":"Ready"}
    {"finished":true}
    {invalid
    """
    #expect(ProcessInspection.logLines(text, filter: "").count == 2)
    #expect(ProcessInspection.logLines(text, filter: "FAILED").count == 1)
    #expect(ProcessInspection.logLines(text, filter: "unmatched").isEmpty)
}

@Test func inspectionStartupMatchingUsesPIDExactExecutableOrBundleBoundary() {
    var process = obsProcess(123)
    process.executablePath = "/Applications/Example.app/Contents/MacOS/Example"
    var item = StartupItem(id: "test", name: "Example", detail: "example", category: .agents, isEnabled: true, control: .readOnly)
    item.program = process.executablePath
    #expect(ProcessInspection.matches(item, process: process))
    item.program = "/bin/other"
    item.path = "/Applications/Example.app"
    #expect(ProcessInspection.matches(item, process: process))
    item.path = "/Applications/Exam.app"
    #expect(!ProcessInspection.matches(item, process: process))
    item.pid = 123
    #expect(ProcessInspection.matches(item, process: process))
}

@Test func inspectionRejectsStaleIdentitiesAndReadsOwnContext() throws {
    let start = try #require(ProcessTerminator.startTime(of: getpid()))
    let identity = ProcessIdentity(pid: getpid(), startTime: start)
    #expect(ProcessInspection.isCurrent(identity))
    #expect(!ProcessInspection.isCurrent(ProcessIdentity(pid: getpid(), startTime: start.addingTimeInterval(-1))))
    if !Capabilities.isSandboxed {
        #expect(ProcessInspection.launchContext(pid: getpid()) != nil)
        #expect(ProcessInspection.workingDirectory(pid: getpid()) != nil)
    }
}

@MainActor
@Test func inspectionTabsRenderAtCompactAndWideSizes() async throws {
    let root = try obsTemporaryDirectory()
    let history = try HistoryRepository(databaseURL: root.appendingPathComponent("history.sqlite"))
    let defaults = try #require(UserDefaults(suiteName: "InspectionPreview-\(UUID().uuidString)"))
    let settings = SettingsStore(defaults: defaults, legacyDefaults: nil)
    let scheduler = CollectionScheduler(
        systemCollector: SystemCollector(), processCollector: ProcessCollector(),
        inventoryCollector: InventoryCollector(), networkPortCollector: NetworkPortCollector(),
        history: history, settings: settings.settings, onSystem: { _ in }, onProcesses: { _ in }
    )
    let store = MonitorStore(settingsStore: settings, history: history, scheduler: scheduler)
    var process = obsProcess(getpid())
    process.identity.startTime = try #require(ProcessTerminator.startTime(of: getpid()))
    process.name = "SmackTests"
    process.executablePath = ProcessInfo.processInfo.arguments.first
    for tab in ProcessInspectionTab.allCases {
        for width in [400.0, 900.0] {
            let view = NSHostingView(rootView: ScrollView {
                ProcessInspectionView(store: store, process: process, tab: tab).padding()
            }.frame(width: width, height: 700).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            #expect(view.fittingSize.width <= width)
            if let directory = ProcessInfo.processInfo.environment["SMACK_INSPECTION_PREVIEW_DIR"] {
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let destination = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try png.write(to: destination.appendingPathComponent("\(tab.id)-\(Int(width)).png"))
            }
            window.contentView = nil
        }
    }
}


@Test func inspectionLogCommandAcceptsItsTimeAndSeverityArguments() async {
    guard !Capabilities.isSandboxed else { return }
    let identity = ProcessIdentity(pid: Int32.max, startTime: Date().addingTimeInterval(-10))
    let result = await CommandRunner.run("/usr/bin/log", ProcessInspection.logArguments(
        identity: identity, since: identity.startTime, severity: "Errors"
    ), timeout: 10, outputLimit: 4096)
    #expect(result.status == 0, "log rejected inspection arguments: \(result.error)")
    #expect(!result.timedOut)
}
