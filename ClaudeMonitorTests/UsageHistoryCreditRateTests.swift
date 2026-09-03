import Testing
import Foundation
@testable import ClaudeMonitor

/// `computeRate` is `nonisolated` (pure, no instance state — see its definition), so this
/// suite deliberately stays a plain, non-`@MainActor` struct and calls it synchronously.
///
/// Task 2: a mid-window usage credit resets the utilization NUMERATOR without moving
/// `resetsAt` (see `UsageHistory.record`'s credit-detection branch). Measuring the implied
/// rate's `timeElapsed` from the window's start (as `computeRate` used to, unconditionally)
/// therefore divides a post-credit utilization by a much-too-large denominator, producing a
/// falsely low rate and an over-optimistic projection right when the user starts spending a
/// newly granted credit. `computeRate` now measures `timeElapsed` from the most recent credit's
/// `at` instead, when one exists.
///
/// Real developer archive data motivating this fix: a weekly window credited 55% → 0%, and a
/// 5-hour window credited 32% → 0%, both mid-window.
struct UsageHistoryCreditRateTests {
    private func credit(at: Date, from: Int, to: Int) -> UsageEvent {
        UsageEvent(at: at, kind: .credit, from: from, to: to, fromTimestamp: nil)
    }

    // MARK: - Direction: pre-fix under-reporting vs. post-fix accurate post-credit rate

    @Test func creditAdjustedRateReflectsPostCreditConsumptionNotWindowStart() {
        let windowDuration: TimeInterval = 7 * Constants.Time.secondsPerDay // weekly window
        let windowStart = Date(timeIntervalSince1970: 0)
        let resetsAt = windowStart.addingTimeInterval(windowDuration)

        // A 55% → 0% credit six days into the window (matches the real archived magnitude).
        let creditAt = windowStart.addingTimeInterval(6 * Constants.Time.secondsPerDay)
        // One hour after the credit, utilization is back up to 10% — a genuinely fast
        // post-credit consumption pace (~10%/hour).
        let now = creditAt.addingTimeInterval(Constants.Time.secondsPerHour)
        let currentUtilization = 10

        // The OLD (pre-fix) formula: timeElapsed measured from windowStart, ignoring the
        // credit entirely. Reproduced here (not calling production code) specifically to prove
        // the DIRECTION of the defect this fix corrects.
        let preFixTimeElapsed = now.timeIntervalSince(windowStart)
        let preFixRate = Double(currentUtilization) / preFixTimeElapsed

        let (postFixRate, source) = UsageHistory.computeRate(
            windowDuration: windowDuration,
            currentUtilization: currentUtilization,
            resetsAt: resetsAt,
            events: [credit(at: creditAt, from: 55, to: 0)],
            now: now
        )

        #expect(source == .implied)
        // Pre-fix: dividing by ~6 days instead of 1 hour understates the rate by roughly two
        // orders of magnitude — a falsely optimistic near-zero rate.
        #expect(preFixRate < 0.0001)
        // Post-fix: measured from the credit, the rate correctly reflects ~10%/hour.
        let expectedPostFixRate = Double(currentUtilization) / Constants.Time.secondsPerHour
        #expect(abs(postFixRate - expectedPostFixRate) < 0.0001)
        #expect(postFixRate > preFixRate * 100, "The credit-adjusted rate must be dramatically higher than the pre-fix window-start-based rate.")
    }

    @Test func fiveHourWindowCreditMagnitudeFromRealArchiveData() {
        // Real archived magnitude: a 5-hour window credited 32% → 0%.
        let windowDuration = Constants.Time.secondsPerHour * 5
        let windowStart = Date(timeIntervalSince1970: 0)
        let resetsAt = windowStart.addingTimeInterval(windowDuration)
        let creditAt = windowStart.addingTimeInterval(3600) // one hour into the window
        let now = creditAt.addingTimeInterval(1800) // half an hour after the credit
        let currentUtilization = 8

        let (rate, source) = UsageHistory.computeRate(
            windowDuration: windowDuration,
            currentUtilization: currentUtilization,
            resetsAt: resetsAt,
            events: [credit(at: creditAt, from: 32, to: 0)],
            now: now
        )

        #expect(source == .implied)
        #expect(abs(rate - Double(currentUtilization) / 1800) < 0.0001)
    }

    // MARK: - Multiple credits: use the most recent

    @Test func multipleCreditsUseTheMostRecentOne() {
        let windowDuration: TimeInterval = 604800
        let windowStart = Date(timeIntervalSince1970: 0)
        let resetsAt = windowStart.addingTimeInterval(windowDuration)
        let olderCredit = credit(at: windowStart.addingTimeInterval(86400), from: 40, to: 0)
        let newerCredit = credit(at: windowStart.addingTimeInterval(2 * 86400), from: 20, to: 0)
        let now = newerCredit.at.addingTimeInterval(3600)

        let (rate, _) = UsageHistory.computeRate(
            windowDuration: windowDuration,
            currentUtilization: 5,
            resetsAt: resetsAt,
            events: [olderCredit, newerCredit],
            now: now
        )

        let expected = 5.0 / 3600
        #expect(abs(rate - expected) < 0.0001, "Rate must be measured from the MOST RECENT credit, not an older one.")
    }

    // MARK: - Near-zero elapsed guard

    @Test func nearZeroElapsedAfterCreditIsFlooredNotLeftAbsurd() {
        let windowDuration: TimeInterval = 604800
        let windowStart = Date(timeIntervalSince1970: 0)
        let resetsAt = windowStart.addingTimeInterval(windowDuration)
        let creditAt = windowStart.addingTimeInterval(100)
        // Only one second after the credit.
        let now = creditAt.addingTimeInterval(1)

        let (rate, source) = UsageHistory.computeRate(
            windowDuration: windowDuration,
            currentUtilization: 5,
            resetsAt: resetsAt,
            events: [credit(at: creditAt, from: 50, to: 0)],
            now: now
        )

        #expect(source == .implied)
        // Naive (unfloored) rate would be 5/1 = 5.0/s — an absurd ~18000%/hour spike from a
        // single data point. The floor (Constants.Projection.minRateElapsedAfterCredit = 60s)
        // bounds it to 5/60.
        let naiveRate = 5.0 / 1
        let flooredRate = 5.0 / Constants.Projection.minRateElapsedAfterCredit
        #expect(abs(rate - flooredRate) < 0.0001)
        #expect(rate < naiveRate)
    }

    // MARK: - No credits: behavior unchanged

    @Test func noCreditsMatchesOriginalWindowStartBasedRate() {
        let windowDuration: TimeInterval = 604800
        let windowStart = Date(timeIntervalSince1970: 0)
        let resetsAt = windowStart.addingTimeInterval(windowDuration)
        let now = windowStart.addingTimeInterval(2 * 86400)

        let (rate, source) = UsageHistory.computeRate(
            windowDuration: windowDuration,
            currentUtilization: 30,
            resetsAt: resetsAt,
            events: [],
            now: now
        )

        #expect(source == .implied)
        let expected = 30.0 / (2 * 86400)
        #expect(abs(rate - expected) < 0.0001)
    }

    @Test func noCreditsDefaultParameterMatchesExplicitEmptyEvents() {
        let windowDuration: TimeInterval = 18000
        let windowStart = Date(timeIntervalSince1970: 0)
        let resetsAt = windowStart.addingTimeInterval(windowDuration)
        let now = windowStart.addingTimeInterval(9000)

        let (withDefault, _) = UsageHistory.computeRate(
            windowDuration: windowDuration, currentUtilization: 42, resetsAt: resetsAt, now: now
        )
        let (withExplicitEmpty, _) = UsageHistory.computeRate(
            windowDuration: windowDuration, currentUtilization: 42, resetsAt: resetsAt, events: [], now: now
        )
        #expect(withDefault == withExplicitEmpty)
    }

    @Test func noResetsAtStillReturnsInsufficientRegardlessOfEvents() {
        let (rate, source) = UsageHistory.computeRate(
            windowDuration: 18000,
            currentUtilization: 42,
            resetsAt: nil,
            events: [credit(at: Date(), from: 90, to: 0)]
        )
        #expect(rate == 0)
        #expect(source == .insufficient)
    }
}
