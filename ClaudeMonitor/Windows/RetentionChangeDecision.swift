import Foundation

/// Pure decision logic behind a Preferences retention-years change, extracted from
/// `PreferencesWindowController` so it is unit-testable without driving AppKit alerts/sheets.
/// Owns none of the UI: no field repainting, no `NSAlert`, no persistence. Given the currently
/// persisted value and a proposed new value, it decides whether the change is safe to apply
/// immediately or needs the user to confirm a deletion first — and, in the latter case, exactly
/// how many archived windows would be deleted.
enum RetentionChangeDecision {
    /// What the caller should do about a proposed change from `currentValue` to `newValue`.
    enum Outcome: Equatable {
        /// `newValue == currentValue` — nothing to do.
        case noChange
        /// Safe to apply without asking: either an increase, or a decrease that (as of the
        /// instant the count was computed) would delete nothing.
        case applyImmediately(newValue: Int)
        /// A decrease that would delete `deletingCount` archived windows. The caller must get
        /// user confirmation before applying `newValue`.
        case needsConfirmation(newValue: Int, deletingCount: Int)
    }

    /// Whether the caller needs to compute an archived-window count before calling `evaluate`.
    /// Only a genuine decrease can ever delete anything, so this is the only case worth paying
    /// for that (async, disk-touching) count at all.
    static func requiresArchivedWindowCount(currentValue: Int, newValue: Int) -> Bool {
        newValue != currentValue && newValue < currentValue
    }

    /// Evaluates a proposed retention change. `archivedWindowCount` must already have been
    /// computed by the caller (via `requiresArchivedWindowCount`, only when true) against the
    /// same `now` instant that will later be passed to the prune that applies this decision —
    /// this type only orders the steps, it doesn't own `now`, `UsageHistory`, or any async work
    /// itself, so it stays a plain, synchronous, easily testable function. When
    /// `requiresArchivedWindowCount` is false, pass `0`; it's ignored on every path that doesn't
    /// need it.
    static func evaluate(
        currentValue: Int,
        newValue: Int,
        archivedWindowCount: Int
    ) -> Outcome {
        guard newValue != currentValue else { return .noChange }
        guard newValue < currentValue else { return .applyImmediately(newValue: newValue) }

        guard archivedWindowCount > 0 else { return .applyImmediately(newValue: newValue) }
        return .needsConfirmation(newValue: newValue, deletingCount: archivedWindowCount)
    }
}
