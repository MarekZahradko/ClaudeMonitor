import Foundation
import Testing
@testable import ClaudeMonitor

@Suite @MainActor struct RecentRateTests {

    @Test func computeRecentRateReturnsNilForInsufficientSamples() {
        let now = Date()
        #expect(UsageHistory.computeRecentRate(samples: []) == nil)
        let single = [UtilizationSample(utilization: 50, timestamp: now)]
        #expect(UsageHistory.computeRecentRate(samples: single) == nil)
    }

    @Test func computeRecentRateConstantUtilizationIsZero() {
        let now = Date()
        let samples = (0..<10).map { i in
            UtilizationSample(utilization: 50, timestamp: now.addingTimeInterval(Double(i) * 60))
        }
        let rate = UsageHistory.computeRecentRate(samples: samples)
        #expect(rate != nil)
        #expect(abs(rate! - 0.0) < 0.0001)
    }

    /// A constant-rate signal is the one input for which any weighting scheme whose weights
    /// sum to 1 (a plain average, a hardcoded alpha, or a true EMA) converges to the same
    /// value. This test therefore only pins convergence on a constant signal — it cannot by
    /// itself distinguish the real recency-weighted EMA from a broken weighting scheme. See
    /// the rate-change / symmetry / delta-t tests below for that.
    @Test func computeRecentRateConstantNonzeroRateConvergesToRate() {
        let now = Date()
        let samples = (0..<25).map { i in
            UtilizationSample(utilization: i, timestamp: now.addingTimeInterval(Double(i) * 60))
        }
        let rate = UsageHistory.computeRecentRate(samples: samples)
        #expect(rate != nil)
        let expected = 1.0 / 60.0
        #expect(abs(rate! - expected) < 0.001)
    }

    /// Builds a sample series from a starting utilization plus a list of (utilization delta,
    /// time delta) steps, so each test below can express its scenario as a sequence of
    /// instantaneous rates rather than hand-computing cumulative timestamps/utilizations.
    private func buildSamples(start: Int, steps: [(du: Int, dt: TimeInterval)], startTime: Date) -> [UtilizationSample] {
        var samples = [UtilizationSample(utilization: start, timestamp: startTime)]
        var t = startTime
        var u = start
        for step in steps {
            t = t.addingTimeInterval(step.dt)
            u += step.du
            samples.append(UtilizationSample(utilization: u, timestamp: t))
        }
        return samples
    }

    /// The defining property of an EMA is that recent samples dominate older ones. A long slow
    /// stretch followed by a short fast stretch must land the result much closer to the recent
    /// (fast) rate than a plain arithmetic mean of all steps would. This kills a "plain
    /// arithmetic mean" implementation (which would equal the mean, failing the inequality) and
    /// an "alpha hardcoded to 1" implementation (which would equal the fast rate exactly,
    /// failing the strict upper bound — a true EMA with alpha < 1 never fully reaches the
    /// asymptote in finitely many steps).
    @Test func computeRecentRateWeightsRecentRateChangeOverOlderHistory() {
        let now = Date()
        // 15 steps at rate 0, then 5 steps at rate 0.1 (6 util / 60s), all spaced by tau (60s).
        let slowSteps: [(Int, TimeInterval)] = Array(repeating: (0, 60.0), count: 15)
        let fastSteps: [(Int, TimeInterval)] = Array(repeating: (6, 60.0), count: 5)
        let samples = buildSamples(start: 0, steps: slowSteps + fastSteps, startTime: now)

        let rate = UsageHistory.computeRecentRate(samples: samples)
        #expect(rate != nil)

        let fastRate = 0.1
        let arithmeticMean = (15 * 0.0 + 5 * fastRate) / 20.0
        #expect(rate! > arithmeticMean, "a recency-weighted EMA must land above the plain average of all steps")
        #expect(rate! < fastRate, "a true EMA with alpha < 1 must not fully reach the most recent instantaneous rate")
        #expect(rate! > fastRate * 0.9, "the recent fast stretch should dominate, landing close to its own rate")
    }

    /// The same multiset of step-rates in the opposite order must produce a different result.
    /// An order-insensitive result (equivalent to a plain average over the whole series) proves
    /// the implementation is not weighting by recency at all — this test kills that mutation
    /// outright, independent of the inequality-based test above.
    @Test func computeRecentRateOrderOfStepsChangesResult() {
        let now = Date()
        let slowSteps: [(Int, TimeInterval)] = Array(repeating: (0, 60.0), count: 15)
        let fastSteps: [(Int, TimeInterval)] = Array(repeating: (6, 60.0), count: 5)

        let slowThenFast = buildSamples(start: 0, steps: slowSteps + fastSteps, startTime: now)
        let fastThenSlow = buildSamples(start: 0, steps: fastSteps + slowSteps, startTime: now)

        let rateSlowThenFast = UsageHistory.computeRecentRate(samples: slowThenFast)
        let rateFastThenSlow = UsageHistory.computeRecentRate(samples: fastThenSlow)
        #expect(rateSlowThenFast != nil)
        #expect(rateFastThenSlow != nil)

        // Ending on the fast stretch must land much higher than ending on the slow stretch,
        // even though both series contain the exact same 20 steps.
        #expect(rateSlowThenFast! - rateFastThenSlow! > 0.05)
    }

    /// Two series with identical per-step instantaneous rates (same deltaUtil/deltaTime ratio)
    /// but different absolute time gaps must still weight differently, since alpha depends on
    /// deltaTime (alpha = 1 - exp(-deltaTime/tau)). This kills an implementation whose
    /// per-step weighting ignores deltaTime entirely (e.g. a fixed per-step alpha) — such an
    /// implementation would produce identical results for both series below, since every step's
    /// own instantaneous rate is identical between them.
    @Test func computeRecentRateDeltaTimeAffectsWeighting() {
        let now = Date()
        let slowSteps: [(Int, TimeInterval)] = Array(repeating: (0, 60.0), count: 15)
        // Both fast phases have instantaneous rate 0.1 (util/sec), but very different deltaTime
        // relative to tau (60s): 10s (alpha small, slow to adapt) vs 120s (alpha large, fast to adapt).
        let fastStepsShortDt: [(Int, TimeInterval)] = Array(repeating: (1, 10.0), count: 5)
        let fastStepsLongDt: [(Int, TimeInterval)] = Array(repeating: (12, 120.0), count: 5)

        let samplesShortDt = buildSamples(start: 0, steps: slowSteps + fastStepsShortDt, startTime: now)
        let samplesLongDt = buildSamples(start: 0, steps: slowSteps + fastStepsLongDt, startTime: now)

        let rateShortDt = UsageHistory.computeRecentRate(samples: samplesShortDt)
        let rateLongDt = UsageHistory.computeRecentRate(samples: samplesLongDt)
        #expect(rateShortDt != nil)
        #expect(rateLongDt != nil)

        // Larger deltaTime steps (relative to tau) produce a larger alpha, adapting to the new
        // rate faster, so the long-deltaTime series must land closer to the fast rate (0.1).
        #expect(rateLongDt! > rateShortDt!)
    }

    @Test func computeRecentRateShortBurstBarelyMovesEma() {
        let now = Date()
        var samples: [UtilizationSample] = (0..<20).map { i in
            UtilizationSample(utilization: 0, timestamp: now.addingTimeInterval(Double(i) * 60))
        }
        samples.append(UtilizationSample(utilization: 1, timestamp: now.addingTimeInterval(Double(19) * 60 + 2)))
        let rate = UsageHistory.computeRecentRate(samples: samples)
        #expect(rate != nil)
        #expect(rate! > 0.01 && rate! < 0.025,
                "ema after short 2s burst should be ~0.016, got \(rate!)")
    }

    @Test func computeRecentRateResetsOnNegativeDelta() {
        let now = Date()
        let utils = [90, 95, 0, 1, 2]
        let samples = utils.enumerated().map { (i, u) in
            UtilizationSample(utilization: u, timestamp: now.addingTimeInterval(Double(i) * 60))
        }
        let rate = UsageHistory.computeRecentRate(samples: samples)
        #expect(rate != nil)
        #expect(rate! >= 0)
        #expect(rate! < 0.083)
    }

    @Test func computeRecentRateSkipsZeroDeltaTime() {
        let now = Date()
        let s1 = UtilizationSample(utilization: 50, timestamp: now)
        let s2 = UtilizationSample(utilization: 60, timestamp: now)
        let s3 = UtilizationSample(utilization: 61, timestamp: now.addingTimeInterval(60))
        let rate = UsageHistory.computeRecentRate(samples: [s1, s2, s3])
        #expect(rate != nil)
        #expect(abs(rate! - 1.0/60.0) < 0.001)
    }

    @Test func computeRecentRateCustomTau() {
        let now = Date()
        var samples: [UtilizationSample] = (0..<10).map { i in
            UtilizationSample(utilization: i, timestamp: now.addingTimeInterval(Double(i) * 60))
        }
        samples.append(UtilizationSample(utilization: 15, timestamp: now.addingTimeInterval(9 * 60 + 1)))

        let rateFastTau = UsageHistory.computeRecentRate(samples: samples, tau: 1)
        let rateSlowTau = UsageHistory.computeRecentRate(samples: samples, tau: 600)

        #expect(rateFastTau != nil)
        #expect(rateSlowTau != nil)
        #expect(rateFastTau! > rateSlowTau!)
    }
}
