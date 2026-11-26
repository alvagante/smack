import Testing

/// Timings on shared CI runners are noisy: a small overrun warns, a larger one fails.
enum PerformanceBudget {
    enum Verdict { case within, warning, exceeded }

    /// Fraction over the budget that is still tolerated.
    static let tolerance = 0.5

    static func verdict(_ value: Double, limit: Double) -> Verdict {
        if value < limit { return .within }
        return value <= limit * (1 + tolerance) ? .warning : .exceeded
    }

    static func check(_ name: String, milliseconds value: Double, limit: Double,
                      sourceLocation: SourceLocation = #_sourceLocation) {
        switch verdict(value, limit: limit) {
        case .within: break
        // GitHub Actions turns this line into a run annotation.
        case .warning: print("::warning title=Performance budget::\(name): \(value) ms, budget \(limit) ms")
        case .exceeded:
            Issue.record("\(name): \(value) ms exceeds the \(limit) ms budget by more than \(Int(tolerance * 100))%",
                         sourceLocation: sourceLocation)
        }
    }
}

@Test(arguments: [
    (4.9, PerformanceBudget.Verdict.within),
    (5.0, .warning),
    (7.5, .warning),
    (7.6, .exceeded),
])
func performanceBudgetToleratesSmallDeviations(value: Double, expected: PerformanceBudget.Verdict) {
    #expect(PerformanceBudget.verdict(value, limit: 5) == expected)
}
