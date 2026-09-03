import Testing
import Foundation
import AppKit
@testable import ClaudeMonitor

/// Tests for `GraphDrawer.timeRange` — the graph's x-axis domain computation
/// (`GraphDrawer.swift`). Regression coverage for the reported defect: a sample stored before
/// the window's own start used to stretch the axis backwards (`min(earliestSample, windowStart)`),
/// which misplaced "now" far to the right of where it belongs on the axis. Follows
/// `GraphDrawerCreditTests`'s precedent of exercising pure value-returning functions directly.
struct GraphTimeRangeTests {
    private let fiveHours: TimeInterval = 5 * 60 * 60
    private let sevenDays: TimeInterval = 7 * 24 * 60 * 60

    @Test func axisSpansExactlyFiveHourWindowDuration() {
        let resetsAt = Date(timeIntervalSince1970: 100_000)
        let range = GraphDrawer.timeRange(resetsAt: resetsAt, duration: fiveHours)
        #expect(range.upperBound.timeIntervalSince(range.lowerBound) == fiveHours)
    }

    @Test func axisSpansExactlySevenDayWindowDuration() {
        let resetsAt = Date(timeIntervalSince1970: 100_000)
        let range = GraphDrawer.timeRange(resetsAt: resetsAt, duration: sevenDays)
        #expect(range.upperBound.timeIntervalSince(range.lowerBound) == sevenDays)
    }

    /// This is the regression test for the reported defect. Against the old
    /// `min(earliestSample, windowStart)` logic, a sample 2.5h before `windowStart` would have
    /// stretched this 5-hour window's axis out to 7.5 hours. It must not.
    @Test func preWindowSampleDoesNotWidenTheAxis() {
        let resetsAt = Date(timeIntervalSince1970: 100_000)
        let windowStart = resetsAt.addingTimeInterval(-fiveHours)
        // A sample recorded 2.5h before the window even started — mirrors the user's real,
        // measured 5-hour window where samples predated `windowStart` by hours.
        let preWindowSampleTime = windowStart.addingTimeInterval(-2.5 * 60 * 60)
        #expect(preWindowSampleTime < windowStart)

        let range = GraphDrawer.timeRange(resetsAt: resetsAt, duration: fiveHours)
        #expect(range.lowerBound == windowStart)
        #expect(range.upperBound.timeIntervalSince(range.lowerBound) == fiveHours)
    }

    /// Expressed as the user-visible property: with 4.5h remaining of a 5h window, "now" sits
    /// one tenth of the way along the axis, not near the middle.
    @Test func nowSitsOneTenthAlongTheAxisWithFourAndHalfHoursRemaining() {
        let resetsAt = Date(timeIntervalSince1970: 100_000)
        let now = resetsAt.addingTimeInterval(-4.5 * 60 * 60)
        let range = GraphDrawer.timeRange(resetsAt: resetsAt, duration: fiveHours)

        let elapsedFraction = now.timeIntervalSince(range.lowerBound) / range.upperBound.timeIntervalSince(range.lowerBound)
        #expect(abs(elapsedFraction - 0.1) < 0.0001)
    }

    @Test func xPositionMapsDomainBoundsOntoRectEdges() {
        let resetsAt = Date(timeIntervalSince1970: 100_000)
        let range = GraphDrawer.timeRange(resetsAt: resetsAt, duration: fiveHours)
        let rect = NSRect(x: 0, y: 0, width: 100, height: 200)
        let drawer = GraphDrawer(analyses: [], selectedIndex: 0, graphRect: rect, now: resetsAt)

        #expect(drawer.xPosition(for: range.lowerBound, in: rect, timeRange: range) == rect.minX)
        #expect(drawer.xPosition(for: range.upperBound, in: rect, timeRange: range) == rect.maxX)
    }

    /// A credit event timestamped before the (now-unwidened) window start falls outside the
    /// domain and must be dropped, not clamped onto the left edge — a clamped marker would
    /// falsely read as "a credit happened right at window start."
    @Test func creditEventBeforeWindowStartProducesNoMarker() {
        let resetsAt = Date(timeIntervalSince1970: 100_000)
        let range = GraphDrawer.timeRange(resetsAt: resetsAt, duration: fiveHours)
        let rect = NSRect(x: 0, y: 0, width: 100, height: 200)

        let entry = WindowEntry(
            key: "five_hour", duration: fiveHours, durationLabel: "5h", modelScope: nil,
            window: UsageWindow(utilization: 10, resetsAt: resetsAt)
        )
        let preWindowEvent = UsageEvent(
            at: range.lowerBound.addingTimeInterval(-1), kind: .credit, from: 20, to: 0, fromTimestamp: nil
        )
        let analysis = WindowAnalysis(
            entry: entry, samples: [], events: [preWindowEvent], consumptionRate: 0,
            projectedAtReset: 10, timeToLimit: nil, rateSource: .insufficient,
            style: Formatting.UsageStyle(level: .normal, isBold: false),
            segments: [], timeSinceLastChange: nil, recentRate: nil
        )
        let drawer = GraphDrawer(analyses: [analysis], selectedIndex: 0, graphRect: rect, now: resetsAt)

        let markers = drawer.visibleCreditMarkers(in: rect, timeRange: range)
        #expect(markers.isEmpty)
    }

    // MARK: - plottableSamples (segment filtering)

    /// The exact reported case: a segment with samples straddling `windowStart`. Against the
    /// old unfiltered/clamped behaviour, every pre-window sample would still be "plotted" (at
    /// `x = rect.minX`); this asserts they are excluded outright and only the genuinely
    /// in-window samples survive.
    @Test func segmentStraddlingWindowStartRetainsOnlyInWindowSamples() {
        let resetsAt = Date(timeIntervalSince1970: 100_000)
        let range = GraphDrawer.timeRange(resetsAt: resetsAt, duration: fiveHours)

        let preWindow1 = UtilizationSample(utilization: 0, timestamp: range.lowerBound.addingTimeInterval(-7200))
        let preWindow2 = UtilizationSample(utilization: 25, timestamp: range.lowerBound.addingTimeInterval(-60))
        let inWindow1 = UtilizationSample(utilization: 30, timestamp: range.lowerBound.addingTimeInterval(600))
        let inWindow2 = UtilizationSample(utilization: 40, timestamp: range.lowerBound.addingTimeInterval(1200))

        let plotted = GraphDrawer.plottableSamples([preWindow1, preWindow2, inWindow1, inWindow2], in: range)

        #expect(plotted == [inWindow1, inWindow2])
        #expect(plotted.allSatisfy { range.contains($0.timestamp) })
    }

    /// A property test with *differing* pre-window utilization values (deliberately not all
    /// equal, unlike the user's real all-zero idle run) so the assertion has real content
    /// regardless of what any particular window's data happens to contain: no plotted point's
    /// timestamp may fall outside the domain. Against clamping (mapping every out-of-domain
    /// timestamp to `rect.minX`/`rect.maxX` instead of dropping it), this would fail because
    /// clamped points still carry an in-domain-looking x while their timestamp is not.
    @Test func differingPreWindowUtilizationsAreAllExcludedNotClamped() {
        let resetsAt = Date(timeIntervalSince1970: 100_000)
        let range = GraphDrawer.timeRange(resetsAt: resetsAt, duration: fiveHours)

        let samples = [
            UtilizationSample(utilization: 0, timestamp: range.lowerBound.addingTimeInterval(-9000)),
            UtilizationSample(utilization: 10, timestamp: range.lowerBound.addingTimeInterval(-5000)),
            UtilizationSample(utilization: 20, timestamp: range.lowerBound.addingTimeInterval(-1000)),
            UtilizationSample(utilization: 30, timestamp: range.lowerBound.addingTimeInterval(600)),
            UtilizationSample(utilization: 40, timestamp: range.lowerBound.addingTimeInterval(1800)),
        ]
        let plotted = GraphDrawer.plottableSamples(samples, in: range)

        #expect(plotted.allSatisfy { range.contains($0.timestamp) })
        #expect(plotted.count == 2)
    }

    /// A segment lying entirely before `windowStart` must produce no plottable samples at all —
    /// the eventual path-builder (`buildSegmentPaths`, guarded at `samples.count >= 2`) is thus
    /// reached with an empty array and draws nothing, rather than a malformed single point or a
    /// wall at the edge.
    @Test func segmentEntirelyBeforeWindowStartProducesNoPlottableSamples() {
        let resetsAt = Date(timeIntervalSince1970: 100_000)
        let range = GraphDrawer.timeRange(resetsAt: resetsAt, duration: fiveHours)

        let samples = [
            UtilizationSample(utilization: 0, timestamp: range.lowerBound.addingTimeInterval(-9000)),
            UtilizationSample(utilization: 15, timestamp: range.lowerBound.addingTimeInterval(-3600)),
        ]
        let plotted = GraphDrawer.plottableSamples(samples, in: range)
        #expect(plotted.isEmpty)
    }

    /// The overwhelmingly common case — a segment fully inside the domain — must be completely
    /// unaffected by the new filtering.
    @Test func segmentEntirelyInsideDomainIsUnchanged() {
        let resetsAt = Date(timeIntervalSince1970: 100_000)
        let range = GraphDrawer.timeRange(resetsAt: resetsAt, duration: fiveHours)

        let samples = [
            UtilizationSample(utilization: 5, timestamp: range.lowerBound.addingTimeInterval(600)),
            UtilizationSample(utilization: 15, timestamp: range.lowerBound.addingTimeInterval(1800)),
            UtilizationSample(utilization: 25, timestamp: range.lowerBound.addingTimeInterval(3600)),
        ]
        let plotted = GraphDrawer.plottableSamples(samples, in: range)
        #expect(plotted == samples)
    }

    // MARK: - clipGapSegment

    /// A gap fully inside the domain draws both the hatch and the connecting dashed line,
    /// unchanged from before filtering existed.
    @Test func gapFullyInsideDomainKeepsBothHatchAndLine() {
        let resetsAt = Date(timeIntervalSince1970: 100_000)
        let range = GraphDrawer.timeRange(resetsAt: resetsAt, duration: fiveHours)
        let before = UtilizationSample(utilization: 10, timestamp: range.lowerBound.addingTimeInterval(600))
        let after = UtilizationSample(utilization: 12, timestamp: range.lowerBound.addingTimeInterval(1800))

        let clipped = GraphDrawer.clipGapSegment(before: before, after: after, in: range)

        #expect(clipped?.hatchStart == before.timestamp)
        #expect(clipped?.hatchEnd == after.timestamp)
        #expect(clipped?.line != nil)
    }

    /// A gap whose `before` endpoint predates the window: the hatch still starts at the domain
    /// edge (the gap truly continues "no data" up to the window boundary), but the dashed line
    /// is dropped rather than drawn from an out-of-domain sample's value as though it had been
    /// observed at `windowStart`.
    @Test func gapStraddlingWindowStartHatchesFromEdgeButDrawsNoLine() {
        let resetsAt = Date(timeIntervalSince1970: 100_000)
        let range = GraphDrawer.timeRange(resetsAt: resetsAt, duration: fiveHours)
        let before = UtilizationSample(utilization: 25, timestamp: range.lowerBound.addingTimeInterval(-3600))
        let after = UtilizationSample(utilization: 5, timestamp: range.lowerBound.addingTimeInterval(600))

        let clipped = GraphDrawer.clipGapSegment(before: before, after: after, in: range)

        #expect(clipped?.hatchStart == range.lowerBound)
        #expect(clipped?.hatchEnd == after.timestamp)
        #expect(clipped?.line == nil)
    }

    /// A gap entirely outside the domain (both endpoints before `windowStart`) is not visible
    /// at all.
    @Test func gapEntirelyBeforeWindowStartProducesNothing() {
        let resetsAt = Date(timeIntervalSince1970: 100_000)
        let range = GraphDrawer.timeRange(resetsAt: resetsAt, duration: fiveHours)
        let before = UtilizationSample(utilization: 25, timestamp: range.lowerBound.addingTimeInterval(-7200))
        let after = UtilizationSample(utilization: 5, timestamp: range.lowerBound.addingTimeInterval(-3600))

        let clipped = GraphDrawer.clipGapSegment(before: before, after: after, in: range)
        #expect(clipped == nil)
    }
}
