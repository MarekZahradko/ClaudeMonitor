import Testing
import AppKit
@testable import ClaudeMonitor

/// The monitor and its route to the menu. These cover the wiring, not the arithmetic —
/// `EnergyModelTests` owns the numbers.
@MainActor
struct EnergyMonitorTests {

    /// The repo's per-run root: swept at the start of the NEXT run, never torn down by this one, so
    /// a failing assertion leaves its files behind for post-mortem. See TestHistoryRoot.
    private func makeTempDirectory() throws -> URL {
        TestHistoryRoot.makeSubdirectory()
    }

    private func writeLog(outputTokens: Int, id: String = "A", to directory: URL) throws {
        let line = """
        {"type":"assistant","requestId":"req_\(id)","uuid":"uuid-\(id)","message":{"id":"msg_\(id)",\
        "model":"claude-opus-5","usage":{"input_tokens":1,"cache_creation_input_tokens":0,\
        "cache_read_input_tokens":10,"output_tokens":\(outputTokens)}}}
        """
        try (line + "\n").data(using: .utf8)!.write(to: directory.appendingPathComponent("\(id).jsonl"))
    }

    private func makeMonitor(logs: URL, root: URL) -> EnergyMonitor {
        EnergyMonitor(logsDirectory: logs, stateFile: root.appendingPathComponent("state.json"))
    }

    // MARK: - Scanning

    @Test func refreshProducesAnEstimateFromTheLogs() async throws {
        let root = try makeTempDirectory()
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try writeLog(outputTokens: 300, to: logs)

        let monitor = makeMonitor(logs: logs, root: root)
        #expect(monitor.estimate == nil, "nothing should be claimed before the first scan")

        await monitor.refresh()

        #expect(monitor.totals?.requests == 1)
        #expect(abs((monitor.estimate?.median ?? 0) - 0.31) < 1e-9)
    }

    @Test func refreshNotifiesSoTheMenuCanRedraw() async throws {
        let root = try makeTempDirectory()
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try writeLog(outputTokens: 300, to: logs)

        let monitor = makeMonitor(logs: logs, root: root)
        var notifications = 0
        monitor.onUpdate = { notifications += 1 }
        await monitor.refresh()
        #expect(notifications == 1)
    }

    // MARK: - Persistence

    /// A restored monitor must show a number before it has scanned anything, otherwise every launch
    /// reads as "no data" for as long as a cold scan takes.
    @Test func persistedStateIsRestoredWithoutScanning() async throws {
        let root = try makeTempDirectory()
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try writeLog(outputTokens: 300, to: logs)

        let first = makeMonitor(logs: logs, root: root)
        await first.refresh()
        first.persist()

        // Second monitor pointed at an empty log directory: anything it reports came from disk.
        let emptyLogs = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: emptyLogs, withIntermediateDirectories: true)
        let second = makeMonitor(logs: emptyLogs, root: root)
        second.restorePersistedState()

        #expect(second.totals?.requests == 1)
        #expect(abs((second.estimate?.median ?? 0) - 0.31) < 1e-9)
    }

    @Test func missingStateFileIsNotAnError() throws {
        let root = try makeTempDirectory()
        let monitor = makeMonitor(logs: root, root: root)
        monitor.restorePersistedState()
        #expect(monitor.estimate == nil)
        #expect(monitor.totals == nil)
    }

    // MARK: - Rendered text

    @Test func nothingIsShownBeforeThereIsAnEstimate() {
        #expect(UsageGraphView.energyText(for: nil) == "")
        #expect(UsageGraphView.energyText(for: .zero) == "")
    }

    @Test func estimateRendersAsIconPlusRange() {
        let text = UsageGraphView.energyText(for: EnergyModel.estimate(outputTokens: 16_023_921))
        #expect(text == "\u{26A1} ~17 kWh")
    }

    // MARK: - Route into the menu

    /// End to end through the value type the menu is built from: an estimate on `MonitorState` has
    /// to reach the label under the graph.
    @Test func estimateOnStateReachesTheGraphView() {
        let view = UsageGraphView()
        let menu = NSMenu()
        let item = NSMenuItem()
        item.tag = MenuBuilder.usageGraphTag
        item.view = view
        menu.addItem(item)

        MenuBuilder.refreshGraph(in: menu, analyses: [], energy: EnergyModel.estimate(outputTokens: 16_023_921))
        #expect(view.currentEnergyText == "\u{26A1} ~17 kWh")

        MenuBuilder.refreshGraph(in: menu, analyses: [], energy: nil)
        #expect(view.currentEnergyText == "")
    }

    @Test func monitorStateCarriesTheEstimate() {
        let estimate = EnergyModel.estimate(outputTokens: 300)
        #expect(MonitorState(energy: estimate).energy == estimate)
        #expect(MonitorState().energy == nil)
    }

    // MARK: - Layout

    /// The energy label must not sit on top of the stats text. Both live on one 20 pt row, so an
    /// overlap would render as two strings drawn over each other rather than as a visible error.
    @Test func statsAndEnergyLabelsDoNotOverlap() {
        let view = UsageGraphView()
        let labels = view.subviews.compactMap { $0 as? NSTextField }
        #expect(labels.count == 2)
        let stats = labels[0], energy = labels[1]
        #expect(stats.alignment == .left, "a centered stats label would drift under the energy label")
        #expect(energy.alignment == .right)
        #expect(stats.frame.maxX <= energy.frame.minX)
        #expect(energy.frame.maxX <= view.bounds.width - MenuBuilder.rowTrailingInset + 0.01)
        #expect(stats.frame.minY == energy.frame.minY, "both belong on the same row")
    }

    /// The reserved width has to fit the widest reading the formatter can produce.
    @Test func reservedWidthFitsTheWidestReading() {
        let widest = UsageGraphView.energyText(for: EnergyEstimate(low: 500_000, median: 1_500_000, high: 2_000_000))
        let measured = NSAttributedString(
            string: widest,
            attributes: [.font: NSFont.systemFont(ofSize: 12)]
        ).size().width
        #expect(measured <= GraphDrawer.Layout.energyLabelWidth, "\(widest) measures \(measured) pt")
    }
}

/// The About window is where the single reading's provenance lives, so it has to actually say it.
@MainActor
struct EnergyAboutTests {

    private func aboutText(energy: EnergyEstimate?) -> String {
        let controller = AboutWindowController(energy: energy)
        defer { controller.window?.close() }
        guard let content = controller.window?.contentView else { return "" }
        var collected = ""
        func walk(_ view: NSView) {
            if let text = view as? NSTextView { collected += text.string }
            if let field = view as? NSTextField { collected += field.stringValue }
            view.subviews.forEach(walk)
        }
        walk(content)
        return collected
    }

    @Test func aboutNamesTheSourceAndTheAccountingBoundary() {
        let text = aboutText(energy: EnergyModel.estimate(outputTokens: 16_112_710))
        #expect(text.contains("Joule"), "the anchor has to be named, not just implied")
        #expect(text.contains("0.31 Wh"))
        #expect(text.contains("datacentre"))
        #expect(text.contains("training"), "readers will assume training is included unless told otherwise")
    }

    /// The menu shows one number; the spread belongs here, computed on the user's own totals.
    @Test func aboutStatesTheSpreadForTheCurrentTotals() {
        let estimate = EnergyModel.estimate(outputTokens: 16_112_710)
        #expect(aboutText(energy: estimate).contains(estimate.rangeDescription))
    }

    @Test func aboutStillRendersBeforeTheFirstScan() {
        let text = aboutText(energy: nil)
        #expect(text.contains("Joule"))
        #expect(!text.contains("works out to"), "no spread can be quoted without totals")
    }
}

/// The stats row under the graph shares one line with the energy reading, so every branch of its
/// text has to fit the width left over. This is the check that was missing when the row first
/// overflowed and truncated mid-date.
@MainActor
struct StatsRowWidthTests {

    /// What the layout actually leaves for the stats text, taken from a real view carrying a
    /// realistic reading rather than recomputed from the constants — the split is dynamic now, so a
    /// formula here could agree with itself while disagreeing with what is drawn.
    private var availableWidth: CGFloat {
        let view = UsageGraphView()
        view.update(energy: EnergyModel.estimate(outputTokens: 16_112_710))
        return labels(in: view).stats.frame.width
    }

    private func labels(in view: UsageGraphView) -> (stats: NSTextField, energy: NSTextField) {
        let fields = view.subviews.compactMap { $0 as? NSTextField }
        return (fields[0], fields[1])
    }

    private func width(_ text: String) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)]).size().width
    }

    private func analysis(
        utilization: Int,
        resetsIn: TimeInterval,
        rate: Double,
        projected: Double,
        timeToLimit: TimeInterval?,
        rateSource: RateSource,
        now: Date
    ) -> WindowAnalysis {
        WindowAnalysis(
            entry: WindowEntry(
                key: "five_hour", duration: 18_000, durationLabel: "5h", modelScope: nil,
                window: UsageWindow(utilization: utilization, resetsAt: now.addingTimeInterval(resetsIn))
            ),
            samples: [], events: [], consumptionRate: rate,
            projectedAtReset: projected, timeToLimit: timeToLimit, rateSource: rateSource,
            style: Formatting.UsageStyle(level: .normal, isBold: false),
            segments: [], timeSinceLastChange: nil, recentRate: nil
        )
    }

    /// Fixed instant so the rendered text is the same on every run.
    private static let now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 16; c.hour = 10; c.minute = 30
        return Calendar.current.date(from: c)!
    }()

    /// Every branch of `statsLabelTextCore`, at values that make each one the widest it gets.
    private func everyBranch() -> [(name: String, text: String)] {
        let now = Self.now
        var out: [(String, String)] = []

        func add(_ name: String, _ a: WindowAnalysis) {
            out.append((name, Formatting.statsLabelText(analysis: a, now: now)))
        }

        add("blocked, today", analysis(utilization: 100, resetsIn: 3600, rate: 16.0 / 3600, projected: 120,
                                      timeToLimit: nil, rateSource: .implied, now: now))
        add("blocked, later day", analysis(utilization: 100, resetsIn: 30 * 3600, rate: 16.0 / 3600, projected: 120,
                                          timeToLimit: nil, rateSource: .implied, now: now))
        add("collecting", analysis(utilization: 40, resetsIn: 7200, rate: 0, projected: 40,
                                   timeToLimit: nil, rateSource: .insufficient, now: now))
        add("idle", analysis(utilization: 22, resetsIn: 7200, rate: 0, projected: 22,
                             timeToLimit: nil, rateSource: .implied, now: now))
        add("projected", analysis(utilization: 62, resetsIn: 7200, rate: 16.4 / 3600, projected: 78,
                                  timeToLimit: nil, rateSource: .implied, now: now))
        add("limit, time unknown", analysis(utilization: 62, resetsIn: 7200, rate: 16.4 / 3600, projected: 140,
                                            timeToLimit: nil, rateSource: .implied, now: now))
        add("limit at a time today", analysis(utilization: 62, resetsIn: 40_000, rate: 16.4 / 3600, projected: 140,
                                              timeToLimit: 7200, rateSource: .implied, now: now))
        add("limit on a later day", analysis(utilization: 62, resetsIn: 200_000, rate: 16.4 / 3600, projected: 140,
                                             timeToLimit: 100_000, rateSource: .implied, now: now))
        return out
    }

    @Test func everyStatsBranchFitsBesideTheEnergyReading() {
        for (name, text) in everyBranch() where !text.isEmpty {
            #expect(width(text) <= availableWidth,
                    "\"\(text)\" (\(name)) is \(width(text)) pt, only \(availableWidth) pt available")
        }
    }

    @Test func theEnergyReadingFitsItsOwnReservation() {
        // Widest the formatter can produce: three digits and the largest unit.
        let widest = UsageGraphView.energyText(for: EnergyEstimate(low: 1, median: 123_000_000, high: 200_000_000))
        #expect(width(widest) <= GraphDrawer.Layout.energyLabelWidth, "\(widest) is \(width(widest)) pt")
    }

    /// The clock time names when the limit is reached, not when the window resets — the old wording
    /// said "before reset (at 17:44)", which reads as the reset time and was simply wrong.
    @Test func limitTextNamesWhenTheLimitIsHitNotWhenTheWindowResets() {
        let now = Self.now
        let a = analysis(utilization: 62, resetsIn: 40_000, rate: 16.4 / 3600, projected: 140,
                         timeToLimit: 7200, rateSource: .implied, now: now)
        let text = Formatting.statsLabelText(analysis: a, now: now)
        let limitMoment = Formatting.absoluteTime(now.addingTimeInterval(7200), .hourMinute)
        let resetMoment = Formatting.absoluteTime(now.addingTimeInterval(40_000), .hourMinute)
        #expect(text.contains(limitMoment), "\(text) should name the limit moment \(limitMoment)")
        #expect(!text.contains(resetMoment), "\(text) must not name the reset moment \(resetMoment)")
    }

    @Test func limitTextDropsTheOldBeforeResetWording() {
        for (_, text) in everyBranch() {
            #expect(!text.contains("before reset"))
        }
    }
}


/// The stats row splits its width between the two labels at run time. These pin that split, because
/// a fixed reserve is what made a Croatian string overflow by under two points.
@MainActor
struct StatsRowLayoutTests {

    private func labels(in view: UsageGraphView) -> (stats: NSTextField, energy: NSTextField) {
        let fields = view.subviews.compactMap { $0 as? NSTextField }
        return (fields[0], fields[1])
    }

    private func width(_ text: String) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)]).size().width
    }

    @Test func energyLabelShrinksToItsTextAndHandsTheRestToTheStatsText() {
        let view = UsageGraphView()
        view.update(energy: EnergyModel.estimate(outputTokens: 16_112_710))
        let (stats, energy) = labels(in: view)

        let text = UsageGraphView.energyText(for: EnergyModel.estimate(outputTokens: 16_112_710))
        #expect(energy.frame.width >= width(text))
        #expect(energy.frame.width <= width(text) + 8, "the label should fit its text, not a fixed reserve")

        let usable = view.bounds.width - MenuBuilder.rowTrailingInset * 2
        #expect(stats.frame.width == usable - energy.frame.width - GraphDrawer.Layout.statsEnergyGap)
        #expect(stats.frame.maxX <= energy.frame.minX)
    }

    /// Before the first scan there is no reading, and the whole row belongs to the stats text.
    @Test func withNoReadingTheStatsTextGetsTheWholeRow() {
        let view = UsageGraphView()
        view.update(energy: nil)
        let (stats, energy) = labels(in: view)
        #expect(energy.frame.width == 0)
        #expect(stats.frame.width == view.bounds.width - MenuBuilder.rowTrailingInset * 2)
    }

    /// A reading can never eat the row, however large the number gets.
    @Test func anAbsurdReadingIsCappedSoTheStatsTextSurvives() {
        let view = UsageGraphView()
        view.update(energy: EnergyEstimate(low: 1, median: 999_000_000_000, high: 1_000_000_000_000))
        let (stats, energy) = labels(in: view)
        #expect(energy.frame.width <= GraphDrawer.Layout.energyLabelMaxWidth)
        #expect(stats.frame.width > 100, "the stats text must keep a usable share of the row")
    }

    @Test func energyLabelStaysPinnedToTheTrailingEdge() {
        let view = UsageGraphView()
        view.update(energy: EnergyModel.estimate(outputTokens: 300))
        let (_, energy) = labels(in: view)
        #expect(energy.frame.maxX == view.bounds.width - MenuBuilder.rowTrailingInset)
    }
}

/// Diagnostics for the energy label's own box: an NSTextField needs slightly more width than the
/// bare text measures, and a label sized to the text alone clips its last glyph.
@MainActor
struct EnergyLabelFitTests {

    private func energyLabel(in view: UsageGraphView) -> NSTextField {
        view.subviews.compactMap { $0 as? NSTextField }[1]
    }

    @Test func labelIsWideEnoughForItsOwnTextField() {
        let view = UsageGraphView()
        view.update(energy: EnergyModel.estimate(outputTokens: 16_112_710))
        let label = energyLabel(in: view)
        #expect(label.frame.width >= label.fittingSize.width,
                "frame \(label.frame.width) pt vs fitting \(label.fittingSize.width) pt for \"\(label.stringValue)\"")
    }

    /// The row should line up with the rows above and below it, which inset by the header padding.
    @Test func labelTrailingEdgeMatchesTheRestOfTheMenu() {
        let view = UsageGraphView()
        view.update(energy: EnergyModel.estimate(outputTokens: 16_112_710))
        let label = energyLabel(in: view)
        let inset = view.bounds.width - label.frame.maxX
        #expect(inset == MenuBuilder.rowTrailingInset,
                "energy label is inset \(inset) pt, other rows use \(MenuBuilder.rowTrailingInset) pt")
    }
}
