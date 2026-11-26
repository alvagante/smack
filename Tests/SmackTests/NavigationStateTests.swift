import Testing
@testable import Smack

@Suite struct NavigationStateTests {
    @Test func routeChangesRetainHistoryAndSummaryClearsIt() {
        var navigation = NavigationState()

        navigation.navigate(to: .applications)
        navigation.navigate(to: .application("app"))
        navigation.navigate(to: .application("app"))

        #expect(navigation.previousRoute == .applications)
        navigation.goBack()
        #expect(navigation.route == .applications)
        navigation.goBack()
        #expect(navigation.route == .summary)
        #expect(navigation.previousRoute == nil)

        navigation.navigate(to: .history)
        navigation.navigate(to: .summary)
        #expect(navigation.previousRoute == nil)
    }

    @Test func deepLinkFiltersReplaceOldValuesAndRouteChangesClearStaleBanners() {
        var navigation = NavigationState()
        var filters = ViewFilters()
        filters.banner = "Process is not running"
        filters.search = "worker"

        navigation.navigate(to: .applications, filters: filters)
        #expect(navigation.filters == filters)

        navigation.navigate(to: .history)
        #expect(navigation.filters.banner == nil)

        navigation.navigate(to: .settings, filters: ViewFilters())
        #expect(navigation.filters == ViewFilters())
    }

    @Test func projectSectionIsConsumedOnce() {
        var navigation = NavigationState()

        navigation.openProject("/repo", section: .docker)

        #expect(navigation.route == .project("/repo"))
        #expect(navigation.takeProjectSection() == .docker)
        #expect(navigation.takeProjectSection() == nil)
    }
}
