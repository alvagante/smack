import Testing
@testable import Smack

@MainActor
@Test func applicationSortingReversesWhenSelectingActiveColumn() {
    let model = ApplicationListViewModel()
    #expect(model.sort == .cpu)
    #expect(!model.ascending)

    model.toggleSort(.cpu)
    #expect(model.sort == .cpu)
    #expect(model.ascending)
}

@MainActor
@Test func applicationSortingSelectsMetricAndDirection() {
    let model = ApplicationListViewModel()
    model.toggleSort(.energy)
    #expect(model.sort == .energy)
    #expect(!model.ascending)

    model.toggleSort(.name)
    #expect(model.sort == .name)
    #expect(model.ascending)
}
