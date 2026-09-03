import Testing
import Foundation
@testable import ClaudeMonitor

/// `Formatting.detectCriticalReset` no longer re-derives a boundary from raw `resets_at`
/// timestamps — `UsageHistory.detectAndHandleReset` is the single source of truth for that
/// (see its doc comment and ResetDetectionTests). This suite exercises the remaining
/// "was it critical" lookup: given a set of previously-computed `WindowAnalysis` values and
/// the keys that had a genuine boundary this cycle, was any of them critical beforehand.
@MainActor struct CriticalResetTests {

    private func analysis(key: String, utilization: Int, resetsAt: Date, duration: TimeInterval, now: Date) -> WindowAnalysis {
        let entry = WindowEntry(key: key, duration: duration, durationLabel: "d", modelScope: nil,
                                 window: UsageWindow(utilization: utilization, resetsAt: resetsAt))
        return UsageHistory.analyze(entry: entry, samples: [], now: now)
    }

    @Test func firesWhenPreviousWasCriticalAndBoundaryIsGenuine() {
        let now = Date()
        let duration: TimeInterval = 18000
        // 65% used, 50% remaining → projected = 130% → critical.
        let prevReset = now.addingTimeInterval(9000)
        let previous = [analysis(key: "five_hour", utilization: 65, resetsAt: prevReset, duration: duration, now: now)]

        #expect(Formatting.detectCriticalReset(previousAnalyses: previous, genuineBoundaryKeys: ["five_hour"]))
    }

    @Test func doesNotFireWithoutAGenuineBoundaryEvenIfPreviousWasCritical() {
        let now = Date()
        let duration: TimeInterval = 18000
        let prevReset = now.addingTimeInterval(9000)
        let previous = [analysis(key: "five_hour", utilization: 65, resetsAt: prevReset, duration: duration, now: now)]

        // No key in genuineBoundaryKeys — e.g. a 90s resets_at nudge inside the old 9000s
        // band that is drift, not a real boundary. This band had zero test coverage before
        // the Task 5 fix, which is exactly why the regression escaped.
        #expect(!Formatting.detectCriticalReset(previousAnalyses: previous, genuineBoundaryKeys: []))
    }

    @Test func resetNotDetectedWhenPreviousWasNotCritical() {
        let now = Date()
        let duration: TimeInterval = 18000
        let prevReset = now.addingTimeInterval(10000)
        let previous = [analysis(key: "five_hour", utilization: 30, resetsAt: prevReset, duration: duration, now: now)]

        #expect(!Formatting.detectCriticalReset(previousAnalyses: previous, genuineBoundaryKeys: ["five_hour"]))
    }

    @Test func unmatchedKeysAreIgnored() {
        let now = Date()
        let duration: TimeInterval = 18000
        let previous = [analysis(key: "five_hour", utilization: 90, resetsAt: now.addingTimeInterval(1000), duration: duration, now: now)]

        #expect(!Formatting.detectCriticalReset(previousAnalyses: previous, genuineBoundaryKeys: ["seven_day"]))
    }

    @Test func missingResetDatesAreSkipped() {
        let entry = WindowEntry(key: "five_hour", duration: 18000, durationLabel: "5h", modelScope: nil,
                                 window: UsageWindow(utilization: 90, resetsAt: nil))
        let previous = [UsageHistory.analyze(entry: entry, samples: [], now: Date())]

        // No resetsAt → fallback style: utilization 90 is below the fallback critical
        // threshold (95), so not critical.
        #expect(!Formatting.detectCriticalReset(previousAnalyses: previous, genuineBoundaryKeys: ["five_hour"]))
    }

    @Test func resetDetectedOnAnyMatchingCriticalWindow() {
        let now = Date()
        let fiveHour: TimeInterval = 18000
        let sevenDay: TimeInterval = 604_800

        // five_hour: 30% used, not critical. seven_day: 65% used, 50% remaining → critical.
        let previous = [
            analysis(key: "five_hour", utilization: 30, resetsAt: now.addingTimeInterval(1000), duration: fiveHour, now: now),
            analysis(key: "seven_day", utilization: 65, resetsAt: now.addingTimeInterval(sevenDay * 0.5), duration: sevenDay, now: now),
        ]

        #expect(Formatting.detectCriticalReset(previousAnalyses: previous, genuineBoundaryKeys: ["seven_day"]))
    }

    @Test func criticalByProjectionAlsoTriggersReset() {
        let now = Date()
        let duration: TimeInterval = 18000
        // 78% used, 60% remaining → projected ≈ 195% → critical.
        let previousResets = now.addingTimeInterval(duration * 0.6)
        let previous = [analysis(key: "five_hour", utilization: 78, resetsAt: previousResets, duration: duration, now: now)]

        #expect(Formatting.detectCriticalReset(previousAnalyses: previous, genuineBoundaryKeys: ["five_hour"]))
    }

    @Test func exactBoundaryProjection120IsCritical() {
        // utilization=60, 50% time remaining → projected = 120.0 exactly → critical.
        let now = Date()
        let duration: TimeInterval = 18000
        let prevReset = now.addingTimeInterval(9000)
        let previous = [analysis(key: "five_hour", utilization: 60, resetsAt: prevReset, duration: duration, now: now)]

        #expect(Formatting.detectCriticalReset(previousAnalyses: previous, genuineBoundaryKeys: ["five_hour"]))
    }

    @Test func emptyInputs() {
        #expect(!Formatting.detectCriticalReset(previousAnalyses: [], genuineBoundaryKeys: ["five_hour"]))
        #expect(!Formatting.detectCriticalReset(previousAnalyses: [], genuineBoundaryKeys: []))
    }
}
