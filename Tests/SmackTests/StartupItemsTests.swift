import Foundation
import Testing
@testable import Smack

@Suite struct StartupItemsTests {
    static let btm = """
    ========================
     Records for UID -2 : FFFFEEEE-DDDD-CCCC-BBBB-AAAAFFFFFFFE
    ========================

     Items:

     #1:
                     UUID: 4B177D25-B6F7-4D16-B054-0636A39E942C
                     Name: it.lab42.smack.helper
           Developer Name: (null)
                     Type: legacy daemon (0x10010)
                    Flags: [ legacy ] (0x1)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 16.it.lab42.smack.helper
                      URL: file:///Library/LaunchDaemons/it.lab42.smack.helper.plist
          Executable Path: /Library/PrivilegedHelperTools/it.lab42.smack.helper
               Generation: 1
        Parent Identifier: Unknown Developer

    ========================
     Records for UID 501 : A0EA411D-128C-493B-A260-AB516582FE1E
    ========================

     Items:

     #1:
                     UUID: 1
                     Name: Teams
           Developer Name: Microsoft Corporation
                     Type: app (0x2)
                    Flags: [  ] (0)
              Disposition: [disabled, allowed, not notified] (0x2)
               Identifier: 2.com.microsoft.teams2
                      URL: file:///Applications/Microsoft%20Teams.app/
      Embedded Item Identifiers:
        #1: 8.com.microsoft.teams2.agent

     #2:
                     UUID: 2
                     Name: com.microsoft.teams2.agent
           Developer Name: (null)
                     Type: agent (0x8)
                    Flags: [ sandboxed ] (0x40)
              Disposition: [enabled, disallowed, notified] (0x9)
               Identifier: 8.com.microsoft.teams2.agent
                      URL: Contents/Library/LaunchAgents/com.microsoft.teams2.agent.plist
          Executable Path: Contents/Library/LaunchAgents/com.microsoft.teams2.agent
        Parent Identifier: 2.com.microsoft.teams2

     #3:
                     UUID: 3
                     Name: Google Drive
           Developer Name: (null)
                     Type: app (0x2)
                    Flags: [  ] (0)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 2.com.google.drivefs
                      URL: file:///Applications/Google%20Drive.app/
        Bundle Identifier: com.google.drivefs

     #4:
                     UUID: 4
                     Name: freshclam
           Developer Name: (null)
                     Type: legacy agent (0x10008)
                    Flags: [ legacy ] (0x1)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 8.com.security.freshclam
                      URL: file:///Users/al/Library/LaunchAgents/com.security.freshclam.plist
          Executable Path: /opt/homebrew/bin/freshclam
    """

    @Test func parsesBackgroundTaskManagementRecords() throws {
        let records = StartupParsers.btmRecords(Self.btm)
        #expect(records.count == 5)
        let helper = try #require(records.first)
        #expect(helper.uid == -2)
        #expect(helper.type == "legacy daemon")
        #expect(helper.developer == nil)
        #expect(helper.label == "it.lab42.smack.helper")
        let agent = try #require(records.first { $0.type == "agent" })
        #expect(agent.uid == 501)
        #expect(agent.isAllowed == false)
        #expect(agent.isEnabled)
        #expect(agent.label == "com.microsoft.teams2.agent")
        #expect(agent.parentIdentifier == "2.com.microsoft.teams2")
    }

    @Test func parsesDisabledOverridesInBothFormats() {
        let overrides = StartupParsers.disabledOverrides("""
        \tdisabled services = {
        \t\t"com.google.keystone.agent" => disabled
        \t\t"com.docker.helper" => enabled
        \t\t"com.legacy.job" => true
        \t\t"com.legacy.other" => false
        \t}
        """)
        #expect(overrides == ["com.google.keystone.agent": true, "com.docker.helper": false, "com.legacy.job": true, "com.legacy.other": false])
    }

    @Test func parsesRunningServicesOnly() {
        let running = StartupParsers.runningServices("""
        system = {
        \tservices = {
        \t\t   72556      - \tcom.apple.lskdd
        \t\t       0      - \tcom.apple.idle
        \t\t     761      0 \tcom.example.daemon
        \t}
        \tendpoints = {
        \t\t     999      - \tnot.a.service
        \t}
        }
        """)
        #expect(running == ["com.apple.lskdd": 72556, "com.example.daemon": 761])
    }

    @Test func togglesCronLinesWithMarker() throws {
        let crontab = "PATH=/usr/bin\n# comment\n* * * * * /bin/echo hi\n#smack-disabled# @daily /bin/backup\n"
        let jobs = StartupParsers.cronJobs(crontab)
        #expect(jobs.map(\.enabled) == [true, false])

        let disabled = try #require(StartupParsers.crontab(crontab, setting: "* * * * * /bin/echo hi", enabled: false))
        #expect(disabled.contains("#smack-disabled# * * * * * /bin/echo hi\n"))
        let enabled = try #require(StartupParsers.crontab(crontab, setting: "@daily /bin/backup", enabled: true))
        #expect(enabled.contains("\n@daily /bin/backup\n"))
        #expect(!enabled.contains(StartupParsers.cronDisabledMarker))
        #expect(StartupParsers.crontab(crontab, setting: "missing", enabled: false) == nil)
    }

    @Test func describesLaunchdTriggers() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "Label": "com.example.job",
            "ProgramArguments": ["/usr/local/bin/job", "--flag"],
            "RunAtLoad": true,
            "StartInterval": 3600,
            "Disabled": true
        ], format: .xml, options: 0)
        let plist = try #require(LaunchdPlist.parse(data, path: "/Library/LaunchDaemons/com.example.job.plist", location: .globalDaemons))
        #expect(plist.program == "/usr/local/bin/job")
        #expect(plist.trigger == "At load · Every 1h")
        #expect(plist.disabled)
        #expect(LaunchdPlist.trigger(["KeepAlive": false]) == "On demand")
    }

    @Test func mergesSourcesIntoStartupItems() throws {
        let sources = StartupSources(
            plists: [
                LaunchdPlist(path: "/Users/al/Library/LaunchAgents/com.security.freshclam.plist", location: .userAgents, label: "com.security.freshclam", program: "/opt/homebrew/bin/freshclam", trigger: "At load", disabled: false),
                LaunchdPlist(path: "/Library/LaunchDaemons/com.example.daemon.plist", location: .globalDaemons, label: "com.example.daemon", program: nil, trigger: "Kept alive", disabled: true),
                LaunchdPlist(path: "/System/Library/LaunchDaemons/com.apple.thing.plist", location: .appleDaemons, label: "com.apple.thing", program: nil, trigger: "On demand", disabled: false)
            ],
            btm: StartupParsers.btmRecords(Self.btm),
            userOverrides: ["com.security.freshclam": true],
            systemOverrides: ["com.example.daemon": false],
            userRunning: ["com.microsoft.teams2.agent": 42],
            runningApplications: ["/Applications/Google Drive.app": 7],
            crontab: "#smack-disabled# 0 3 * * * /bin/backup --full\n",
            removedLoginItems: ["/Applications/Slack.app"],
            uid: 501,
            ownBundlePath: "/Applications/Smack.app"
        )
        let items = StartupItemCollector.items(from: sources)
        func item(_ id: String) throws -> StartupItem { try #require(items.first { $0.id == id }) }

        let freshclam = try item("launchd:/Users/al/Library/LaunchAgents/com.security.freshclam.plist")
        #expect(freshclam.name == "freshclam")
        #expect(freshclam.isEnabled == false)
        #expect(freshclam.control == .launchd(.user, label: "com.security.freshclam"))

        let daemon = try item("launchd:/Library/LaunchDaemons/com.example.daemon.plist")
        #expect(daemon.isEnabled)
        #expect(daemon.requiresAdministrator)

        #expect(try item("launchd:/System/Library/LaunchDaemons/com.apple.thing.plist").isReadOnly)

        let teams = try item("btm:501:8.com.microsoft.teams2.agent")
        #expect(teams.category == .backgroundItems)
        #expect(teams.name == "Teams")
        #expect(teams.developer == "Microsoft Corporation")
        #expect(teams.program == "/Applications/Microsoft Teams.app/Contents/Library/LaunchAgents/com.microsoft.teams2.agent")
        #expect(teams.pid == 42)
        #expect(teams.note != nil)

        let drive = try item("login:/Applications/Google Drive.app")
        #expect(drive.isEnabled)
        #expect(drive.pid == 7)
        #expect(drive.searchTerm == "Google Drive")
        #expect(freshclam.searchTerm == "com.security.freshclam")
        #expect(drive.control == .loginItem(path: "/Applications/Google Drive.app"))
        #expect(try item("login:/Applications/Slack.app").isEnabled == false)
        #expect(!items.contains { $0.detail == "/Applications/Microsoft Teams.app" })

        let cron = try #require(items.first { $0.category == .scheduled })
        #expect(cron.name == "/bin/backup --full")
        #expect(cron.detail == "0 3 * * *")
        #expect(cron.isEnabled == false)
        #expect(cron.control == .cron(line: "0 3 * * * /bin/backup --full"))
    }
}
