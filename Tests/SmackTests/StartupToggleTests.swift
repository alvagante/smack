import Foundation
import Synchronization
import Testing
@testable import Smack

/// Records every command instead of running it, and answers from a script.
private final class RecordingStartupRunner: Sendable {
    struct Call: Equatable {
        var executable: String
        var arguments: [String]
        var input: String?
    }

    private let state: Mutex<(calls: [Call], replies: [StartupCommand.Output])>

    init(_ replies: [StartupCommand.Output] = []) { state = Mutex(([], replies)) }

    var calls: [Call] { state.withLock { $0.calls } }

    var run: StartupItemController.Runner {
        { executable, arguments, input in
            self.state.withLock {
                $0.calls.append(Call(executable: executable, arguments: arguments, input: input))
                return $0.replies.isEmpty ? .init(status: 0, output: "", error: "") : $0.replies.removeFirst()
            }
        }
    }
}

private let hostile = #"evil" & (do shell script "id") & "$(id); '"#

/// The AppleScript source: every value following an `-e`.
private func scriptSource(_ arguments: [String]) -> String {
    zip(arguments, arguments.dropFirst()).filter { $0.0 == "-e" }.map(\.1).joined(separator: "\n")
}

@Suite struct StartupToggleTests {
    @Test(arguments: [(true, "enable"), (false, "disable")])
    func userAgentsUseLaunchctlInTheUserDomain(enabled: Bool, action: String) async {
        let runner = RecordingStartupRunner()
        let result = await StartupItemController.setEnabled(enabled, control: .launchd(.user, label: "com.example.agent"), run: runner.run)
        #expect(result == .completed)
        #expect(runner.calls == [.init(executable: "/bin/launchctl", arguments: [action, "gui/\(getuid())/com.example.agent"])])
    }

    @Test func systemDaemonsPassTheLabelAsAnArgumentQuotedByAppleScript() async throws {
        let runner = RecordingStartupRunner()
        _ = await StartupItemController.setEnabled(false, control: .launchd(.system, label: hostile), run: runner.run)
        let call = try #require(runner.calls.first)
        #expect(call.executable == "/usr/bin/osascript")
        #expect(call.arguments.suffix(2) == ["disable", "system/\(hostile)"])
        let source = scriptSource(call.arguments)
        #expect(source.contains("quoted form of item 2 of argv"))
        #expect(source.contains("with administrator privileges"))
        // The label appears only inside the escaped prompt string, so its quotes cannot end the literal.
        #expect(!source.contains(hostile))
        #expect(source.contains(#"evil\" & (do shell script \"id\")"#))
    }

    @Test(arguments: [(true, "make login item"), (false, "delete (every login item")])
    func loginItemPathsNeverEnterTheScript(enabled: Bool, command: String) async throws {
        let runner = RecordingStartupRunner()
        _ = await StartupItemController.setEnabled(enabled, control: .loginItem(path: hostile), run: runner.run)
        let call = try #require(runner.calls.first)
        #expect(call.arguments.last == hostile)
        #expect(scriptSource(call.arguments).contains(command))
        #expect(!scriptSource(call.arguments).contains("evil"))
    }

    @Test func cronToggleRewritesOnlyTheChosenLine() async throws {
        let crontab = "MAILTO=me\n0 * * * * /bin/a\n5 * * * * /bin/b\n"
        let runner = RecordingStartupRunner([.init(status: 0, output: crontab, error: "")])
        let result = await StartupItemController.setEnabled(false, control: .cron(line: "0 * * * * /bin/a"), run: runner.run)
        #expect(result == .completed)
        #expect(runner.calls.map(\.arguments) == [["-l"], ["-"]])
        let written = try #require(runner.calls.last?.input)
        #expect(written == StartupParsers.crontab(crontab, setting: "0 * * * * /bin/a", enabled: false))
        #expect(written.contains("MAILTO=me") && written.contains("\n5 * * * * /bin/b"))
    }

    @Test(arguments: [
        StartupCommand.Output(status: 1, output: "", error: "crontab: no crontab"),
        StartupCommand.Output(status: 0, output: "5 * * * * /bin/other\n", error: "")
    ])
    func cronIsNotWrittenWhenItCannotBeReadOrHasChanged(reply: StartupCommand.Output) async {
        let runner = RecordingStartupRunner([reply])
        let result = await StartupItemController.setEnabled(false, control: .cron(line: "0 * * * * /bin/a"), run: runner.run)
        #expect(result == .failed("The crontab changed since it was read. Refresh and try again."))
        #expect(runner.calls.map(\.arguments) == [["-l"]])
    }

    @Test func readOnlyItemsRunNothing() async {
        let runner = RecordingStartupRunner()
        let result = await StartupItemController.setEnabled(false, control: .readOnly, run: runner.run)
        #expect(result == .failed("This item cannot be changed from Smack."))
        #expect(runner.calls.isEmpty)
    }

    @Test func commandFailuresAreReportedInPlainWords() {
        func result(_ status: Int32, _ error: String) -> StartupToggleResult {
            StartupItemController.result(.init(status: status, output: "", error: error))
        }
        #expect(result(0, "") == .completed)
        #expect(result(1, "execution error: User canceled. (-128)") == .cancelled)
        #expect(result(1, "Not authorized (-1743)") == .failed("Smack is not allowed to control System Events. Allow it in System Settings › Privacy & Security › Automation."))
        #expect(result(3, "  boom\n") == .failed("boom"))
        #expect(result(3, " \n") == .failed("The command exited with status 3."))
    }

    @MainActor @Test(arguments: [StartupToggleResult.completed, .cancelled, .failed("nope")])
    func theModelChangesItsStateOnlyAfterASuccessfulToggle(outcome: StartupToggleResult) async throws {
        let suite = "StartupToggleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = StartupItem(id: "login:/A.app", name: "A", detail: "/A.app", category: .loginItems,
                               trigger: "At login", isEnabled: true, control: .loginItem(path: "/A.app"))
        let model = StartupItemsModel(defaults: defaults) { _, _ in outcome }
        model.receiveCached(StartupInventory(timestamp: Date(), items: [item], warnings: [],
                                             includesBackgroundTasks: false, includedCategories: [.loginItems]))
        model.setEnabled(false, for: item)
        #expect(model.pending == [item.id])
        for _ in 0..<10_000 where !model.pending.isEmpty { await Task.yield() }
        try #require(model.pending.isEmpty, "the toggle never finished")
        #expect(model.inventory?.items.first?.isEnabled == (outcome != .completed))
        #expect(model.removedLoginItems == (outcome == .completed ? ["/A.app"] : []))
        #expect(model.error == (outcome == .failed("nope") ? "A could not be disabled: nope" : nil))
    }
}
