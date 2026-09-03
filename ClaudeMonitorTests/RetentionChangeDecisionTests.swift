import Testing
@testable import ClaudeMonitor

/// Covers the pure decision logic behind a Preferences retention-years change (extracted from
/// `PreferencesWindowController` specifically so it's testable without driving `NSAlert`/sheets,
/// and without any async/actor-isolation concerns of its own — it's a plain synchronous
/// function). What this suite does NOT cover, because it is pure AppKit wiring with no decision
/// logic of its own: presenting/dismissing the actual confirmation sheet, repainting the
/// stepper/field/unit label, awaiting `usageHistory.archivedWindowCount` and capturing/threading
/// a single `Date()` through it and the eventual prune, and the "ignore input while a
/// confirmation sheet is on screen" concurrency policy (all in
/// `PreferencesWindowController.applyRetentionChange`/`confirmRetentionDecrease`).
@Suite struct RetentionChangeDecisionTests {
    @Test func noChangeWhenValuesAreEqual() {
        let outcome = RetentionChangeDecision.evaluate(
            currentValue: 2,
            newValue: 2,
            archivedWindowCount: 5
        )
        #expect(outcome == .noChange)
    }

    @Test func increaseNeverRequiresAnArchivedWindowCount() {
        #expect(!RetentionChangeDecision.requiresArchivedWindowCount(currentValue: 2, newValue: 5))
    }

    @Test func noChangeNeverRequiresAnArchivedWindowCount() {
        #expect(!RetentionChangeDecision.requiresArchivedWindowCount(currentValue: 2, newValue: 2))
    }

    @Test func decreaseRequiresAnArchivedWindowCount() {
        #expect(RetentionChangeDecision.requiresArchivedWindowCount(currentValue: 5, newValue: 2))
    }

    @Test func increaseAppliesImmediately() {
        // An increase must never delete anything, so the count passed in is irrelevant — it's
        // only ever fetched (via requiresArchivedWindowCount) on the decrease path.
        let outcome = RetentionChangeDecision.evaluate(
            currentValue: 2,
            newValue: 5,
            archivedWindowCount: 0
        )
        #expect(outcome == .applyImmediately(newValue: 5))
    }

    @Test func decreaseWithNothingToDeleteAppliesImmediately() {
        let outcome = RetentionChangeDecision.evaluate(
            currentValue: 5,
            newValue: 2,
            archivedWindowCount: 0
        )
        #expect(outcome == .applyImmediately(newValue: 2))
    }

    @Test func decreaseThatWouldDeleteSomethingNeedsConfirmation() {
        let outcome = RetentionChangeDecision.evaluate(
            currentValue: 5,
            newValue: 1,
            archivedWindowCount: 3
        )
        #expect(outcome == .needsConfirmation(newValue: 1, deletingCount: 3))
    }

    @Test func decreaseAtTheMinimumBoundaryStillEvaluatesNormally() {
        // `Constants.History.clampRetentionYears` (tested separately in
        // UsageHistoryRetentionTests) is what actually restricts input to
        // [minRetentionYears, maxRetentionYears]; this type just has to behave correctly for a
        // decrease all the way down to the minimum, since the clamp doesn't shield it from that.
        let outcome = RetentionChangeDecision.evaluate(
            currentValue: Constants.History.maxRetentionYears,
            newValue: Constants.History.minRetentionYears,
            archivedWindowCount: 42
        )
        #expect(outcome == .needsConfirmation(newValue: Constants.History.minRetentionYears, deletingCount: 42))
    }
}
