import Testing
import Foundation
@testable import ClaudeMonitor

struct DemoDataTests {

    @Test func scenario1DemonstratesOutageWithIncidents() {
        let frame = DemoData.scenario(1)
        // Scenario 1 exists to demonstrate the menu bar's outage icon and the incident list —
        // so its worst component must actually be worse than operational, and there must be
        // more than one incident to show the incident list rendering multiple entries.
        let worst = frame.status.components.map(\.status).max()
        #expect(worst != nil && worst! > .operational)
        #expect(frame.status.incidents.count == 2)
        #expect(frame.usage.entries.map(\.key).contains("five_hour"))
        #expect(frame.usage.entries.map(\.key).contains("seven_day"))
    }

    @Test func scenario2DemonstratesDegradedPerformanceWithOneIncident() {
        let frame = DemoData.scenario(2)
        // Scenario 2 demonstrates a milder, single-incident case than scenario 1.
        #expect(frame.status.components.contains { $0.status == .degradedPerformance })
        #expect(frame.status.incidents.count == 1)
        #expect(frame.usage.entries.map(\.key).contains("five_hour"))
        #expect(frame.usage.entries.map(\.key).contains("seven_day"))
    }

    @Test func scenario3DemonstratesHighUtilizationWithNoIncidents() {
        let frame = DemoData.scenario(3)
        // Scenario 3 demonstrates all-systems-operational alongside near-limit usage, so the
        // orange/red usage styling — not the status icon — is what's on display.
        #expect(frame.status.components.allSatisfy { $0.status == .operational })
        #expect(frame.status.incidents.isEmpty)
        #expect(frame.usage.entries.contains { $0.window.utilization >= 80 })
        // Scenario 3 additionally demonstrates a model-specific window alongside an all-model one.
        #expect(frame.usage.entries.contains { $0.modelScope != nil })
    }

    @Test func scenario4DemonstratesBlockedWindowWithNoIncidents() {
        let frame = DemoData.scenario(4)
        // Scenario 4 demonstrates a fully-blocked (>=100%) window with everything else healthy.
        #expect(frame.status.components.allSatisfy { $0.status == .operational })
        #expect(frame.status.incidents.isEmpty)
        #expect(frame.usage.entries.contains { $0.window.utilization >= 100 })
        #expect(frame.usage.entries.contains { $0.modelScope != nil })
    }

    @Test func scenario4HasBlockedWindow() {
        let frame = DemoData.scenario(4)
        let blocked = frame.usage.entries.first { $0.window.utilization >= 100 }
        #expect(blocked != nil)
    }

    @Test func defaultFallsBackToScenario1() {
        let frame1 = DemoData.scenario(1)
        let frameDef = DemoData.scenario(99)
        #expect(frame1.usage.entries.count == frameDef.usage.entries.count)
        #expect(frame1.status.components.count == frameDef.status.components.count)
        // Verify the actual data matches, not just the shape (resetsAt is excluded — it's generated from Date() at call time)
        #expect(frame1.usage.entries.first?.window.utilization == frameDef.usage.entries.first?.window.utilization)
        #expect(frame1.usage.entries.map(\.key) == frameDef.usage.entries.map(\.key))
    }

    @Test func rotationOrderCoversAllScenarios() {
        let order = Constants.Demo.rotationOrder
        #expect(Set(order) == Set(1...7))
    }

    @Test func allScenariosHaveValidWindowKeys() {
        for i in 1...7 {
            let frame = DemoData.scenario(i)
            for entry in frame.usage.entries {
                #expect(WindowKeyParser.parse(entry.key) != nil,
                        "Scenario \(i): key '\(entry.key)' is not parseable")
            }
        }
    }

    @Test func allScenariosHaveFutureResetDates() {
        let now = Date()
        for i in 1...7 {
            let frame = DemoData.scenario(i)
            let entriesWithResetDate = frame.usage.entries.filter { $0.window.resetsAt != nil }
            #expect(!entriesWithResetDate.isEmpty,
                    "Scenario \(i): no entries have a resetsAt date — cannot verify future reset dates")
            for entry in entriesWithResetDate {
                #expect(entry.window.resetsAt! > now,
                        "Scenario \(i): key '\(entry.key)' has past reset date")
            }
        }
    }

    @Test func allScenariosHaveConsistentComponentCount() {
        for i in 1...7 {
            let frame = DemoData.scenario(i)
            #expect(frame.status.components.count == 4, "Scenario \(i) should have 4 components")
        }
    }

    @Test func entriesAreSorted() {
        for i in 1...7 {
            let frame = DemoData.scenario(i)
            let entries = frame.usage.entries
            for j in 1..<entries.count {
                #expect(entries[j - 1] < entries[j] || entries[j - 1] == entries[j],
                        "Scenario \(i): entries not sorted at index \(j)")
            }
        }
    }

    // MARK: - DemoSamples Consistency

    @Test func demoSamplesKeysMatchUsageEntriesForScenariosWithFullCoverage() {
        // Scenarios 1, 2, 4, 5, 6, 7 provide samples for every entry key.
        // Scenario 3 intentionally omits samples for seven_day_sonnet (utilization 0,
        // no resetsAt — nothing meaningful to graph).
        let scenariosWithFullCoverage = [1, 2, 4, 5, 6, 7]
        for i in scenariosWithFullCoverage {
            let frame = DemoData.scenario(i)
            for entry in frame.usage.entries {
                let entrySamples = frame.samples[entry.key]
                #expect(entrySamples != nil,
                        "Scenario \(i): no samples for entry key '\(entry.key)'")
                #expect(entrySamples?.isEmpty == false,
                        "Scenario \(i): empty samples for entry key '\(entry.key)'")
            }
        }
    }

    @Test @MainActor func demoSamplesProduceOrderedTrackedAnalyses() {
        for i in 1...7 {
            let frame = DemoData.scenario(i)
            // `now` must be captured AFTER the frame, never before the loop: demo samples are
            // generated relative to the wall clock at construction time, so a `now` taken
            // earlier sits microseconds BEFORE the final sample and makes timeSinceLastChange
            // legitimately negative — a fixture-ordering artefact, not a defect in analyze().
            let now = Date()
            for entry in frame.usage.entries {
                guard let entrySamples = frame.samples[entry.key], !entrySamples.isEmpty else { continue }
                let analysis = UsageHistory.analyze(entry: entry, samples: entrySamples, now: now)

                // Demo samples are real polled data points, so their analysis must actually
                // contain a tracked segment (not just an inferred or gap segment).
                #expect(analysis.segments.contains { $0.kind == .tracked },
                        "Scenario \(i), key \(entry.key): analysis has no tracked segment")

                // Segments must reproduce the samples in chronological order — a shuffled or
                // reversed segmentation would still pass a mere "not empty" check.
                let timestamps = analysis.segments.flatMap { $0.samples.map(\.timestamp) }
                #expect(zip(timestamps, timestamps.dropFirst()).allSatisfy { $0 <= $1 },
                        "Scenario \(i), key \(entry.key): segment samples are not chronologically ordered")

                if let timeSinceLastChange = analysis.timeSinceLastChange {
                    #expect(timeSinceLastChange >= 0,
                            "Scenario \(i), key \(entry.key): timeSinceLastChange is negative")
                } else {
                    Issue.record("Scenario \(i), key \(entry.key): timeSinceLastChange is nil")
                }
            }
        }
    }

    // MARK: - Connectivity State

    @Test func scenario5HasRecentFailureFlag() {
        let frame = DemoData.scenario(5)
        #expect(frame.isOnline == true)
        #expect(frame.hasRecentFailure == true)
        #expect(frame.isAnyServiceStale == false)
        #expect(frame.lastFailedAt != nil)
    }

    @Test func scenario6IsOfflineAndStale() {
        let frame = DemoData.scenario(6)
        #expect(frame.isOnline == false)
        #expect(frame.isAnyServiceStale == true)
        #expect(frame.hasRecentFailure == false)
        #expect(frame.lastFailedAt != nil)
    }

    @Test func scenario7IsStaleWithConnectionError() {
        let frame = DemoData.scenario(7)
        #expect(frame.isOnline == true)
        #expect(frame.isAnyServiceStale == true)
        #expect(frame.hasRecentFailure == false)
        #expect(frame.lastFailedAt != nil)
    }
}
