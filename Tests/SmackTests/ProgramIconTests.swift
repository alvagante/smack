import Testing
@testable import Smack

@MainActor
struct ProgramIconTests {
    @Test func everyMappedAgentExistsInTheCatalog() {
        let ids = Set(AgentDefinition.catalog.map(\.id))
        for id in AgentApplications.bundleIdentifiers.keys { #expect(ids.contains(id)) }
    }

    @Test func unknownAgentHasNoApplication() {
        #expect(AgentApplications.installedBundleIdentifier(for: "no-such-agent") == nil)
    }
}
