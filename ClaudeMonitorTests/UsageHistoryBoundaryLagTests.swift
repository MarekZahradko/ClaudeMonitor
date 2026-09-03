import Foundation
import Testing
@testable import ClaudeMonitor

// Real 2026-08-17 incident: the 5-hour window's `resets_at` was 23:39:59. The API dropped
// utilization to 0 at the very next poll (23:40:01) but had NOT yet advanced `resets_at` —
// a one-poll server lag. `resets_at` only advanced forward one poll later. Before the fix in
// UsageHistory.swift's genuine-boundary branch of `detectAndHandleReset`, this produced two
// defects: (a) a bogus `.credit` event (80 -> 0) recorded and archived as if the user had been
// credited usage, and (b) the post-reset (0%) sample mis-attributed to the OLD, archived
// window instead of the new one. These tests pin the fix: partitioning by the OLD window's
// known `resets_at` boundary at the moment a genuine boundary is proven, with events that
// straddle that boundary dropped entirely rather than assigned to either side.
@Suite struct UsageHistoryBoundaryLagTests {

    private let identity = "18000" // storageIdentity for "five_hour"
    private let duration: TimeInterval = 18000

    @Test @MainActor func serverLagAtBoundaryPartitionsSamplesAndDropsStraddlingCredit() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        history.switchOrganization(UUID().uuidString)

        let stored = Date(timeIntervalSince1970: 1_786_984_799) // the OLD window's resets_at
        let tPeak = stored.addingTimeInterval(-2)   // 80% sample just before the boundary
        let tAfter = stored.addingTimeInterval(2)   // 0% sample just after (server lag: resets_at unchanged)

        // Simulate the state right before the fix-triggering poll: `record()` already saw the
        // 80 -> 0 drop while `resets_at` was still `stored`, so it recorded a bogus credit event.
        history.storage[identity] = WindowInstance(
            id: UUID(),
            storageIdentity: identity,
            resetsAt: stored,
            firstObservedAt: stored.addingTimeInterval(-3600),
            samples: [
                UtilizationSample(utilization: 30, timestamp: stored.addingTimeInterval(-1800)),
                UtilizationSample(utilization: 80, timestamp: tPeak),
                UtilizationSample(utilization: 0, timestamp: tAfter),
            ],
            events: [
                UsageEvent(at: tAfter, kind: .credit, from: 80, to: 0, fromTimestamp: tPeak),
            ]
        )

        // The following poll: resets_at has now genuinely advanced, and `now` is past `stored`.
        let entry = makeEntry(key: "five_hour", utilization: 0, resetsAt: stored.addingTimeInterval(duration))
        let newResetsAt = stored.addingTimeInterval(duration)
        let now = tAfter.addingTimeInterval(55)
        let didReset = await history.detectAndHandleReset(entry: entry, newResetsAt: newResetsAt, at: now)
        #expect(didReset)

        // New instance: ONLY the post-boundary (0%) sample, no fabricated credit event, and
        // firstObservedAt equal to that sample's own timestamp (not `now`).
        let newInstance = history.storage[identity]
        #expect(newInstance?.samples.map(\.utilization) == [0])
        #expect(newInstance?.samples.first?.timestamp == tAfter)
        #expect(newInstance?.firstObservedAt == tAfter)
        #expect(newInstance?.events.isEmpty == true)

        // Archive: ONLY the pre-boundary samples, ending at the 80% peak (never the 0% sample),
        // and zero credit events — the 80 -> 0 drop spans the boundary and is a misclassified
        // reset, not a real credit in either window.
        let archiveDir = history.archiveDirectory.appendingPathComponent(identity)
        let archiveFiles = try FileManager.default.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil)
        #expect(archiveFiles.count == 1)
        let decoded = try WindowInstanceCodec.decode(try Data(contentsOf: archiveFiles[0]))
        #expect(decoded.samples.map(\.utilization) == [30, 80])
        #expect(decoded.samples.last?.utilization == 80)
        #expect(decoded.events.isEmpty, "The 80 -> 0 drop spans the boundary and must not survive as a credit event.")
    }

    @Test @MainActor func genuineMidWindowCreditWithUnchangedResetsAtStillReported() async {
        // The developer's original bug report: samples 30 -> 32 -> 0, resets_at completely
        // unchanged, `now` well before resetsAt. Must remain a single instance with a reported
        // credit event, never an archive. (Also covered by
        // WindowInstanceOwnershipTests.midWindowCreditDoesNotSplitOrArchiveTheWindow, which this
        // does not modify or duplicate exactly — restated here for this suite's own record.)
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        history.switchOrganization(UUID().uuidString)
        let now = Date()
        let resetsAt = now.addingTimeInterval(3600)

        let t1 = now.addingTimeInterval(-600)
        let t2 = now.addingTimeInterval(-300)
        let t3 = now

        let e1 = makeEntry(key: "five_hour", utilization: 30, resetsAt: resetsAt)
        let e2 = makeEntry(key: "five_hour", utilization: 32, resetsAt: resetsAt)
        let e3 = makeEntry(key: "five_hour", utilization: 0, resetsAt: resetsAt)

        history.record(entries: [e1], at: t1)
        await history.detectAndHandleReset(entry: e1, newResetsAt: resetsAt)
        history.record(entries: [e2], at: t2)
        await history.detectAndHandleReset(entry: e2, newResetsAt: resetsAt)
        history.record(entries: [e3], at: t3)
        let didReset = await history.detectAndHandleReset(entry: e3, newResetsAt: resetsAt)

        #expect(didReset == false)
        let instance = history.storage[identity]
        #expect(instance?.samples.map(\.utilization) == [30, 32, 0])
        #expect(instance?.events == [UsageEvent(at: t3, kind: .credit, from: 32, to: 0, fromTimestamp: t2)])

        let archiveDir = history.archiveDirectory.appendingPathComponent(identity)
        let archiveFiles = (try? FileManager.default.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil)) ?? []
        #expect(archiveFiles.isEmpty, "A mid-window credit must never produce an archive.")
    }

    @Test @MainActor func boundaryInstantInclusivitySemantics() async throws {
        // Pins the exact inclusivity rule used by the partition: a sample with
        // timestamp == stored belongs to the NEW instance (`>=`), matching the pre-existing
        // `windowStart` convention already used by the legacy-reconstruction path above it in
        // UsageHistory.swift. Only a sample strictly BEFORE `stored` is archived.
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        history.switchOrganization(UUID().uuidString)

        let stored = Date(timeIntervalSince1970: 1_786_984_799)
        let tBefore = stored.addingTimeInterval(-1) // exactly one second before the boundary
        let tAt = stored                             // exactly at the boundary instant

        history.storage[identity] = WindowInstance(
            id: UUID(),
            storageIdentity: identity,
            resetsAt: stored,
            firstObservedAt: stored.addingTimeInterval(-3600),
            samples: [
                UtilizationSample(utilization: 79, timestamp: tBefore),
                UtilizationSample(utilization: 0, timestamp: tAt),
            ],
            events: []
        )

        let entry = makeEntry(key: "five_hour", utilization: 0, resetsAt: stored.addingTimeInterval(duration))
        let newResetsAt = stored.addingTimeInterval(duration)
        let now = tAt.addingTimeInterval(55)
        _ = await history.detectAndHandleReset(entry: entry, newResetsAt: newResetsAt, at: now)

        let newInstance = history.storage[identity]
        #expect(newInstance?.samples.map(\.utilization) == [0])
        #expect(newInstance?.samples.first?.timestamp == tAt)

        let archiveDir = history.archiveDirectory.appendingPathComponent(identity)
        let archiveFiles = try FileManager.default.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil)
        let decoded = try WindowInstanceCodec.decode(try Data(contentsOf: archiveFiles[0]))
        #expect(decoded.samples.map(\.utilization) == [79])
    }

    /// The old value-matching lookup (`samples.firstIndex(where: { $0.timestamp == event.at &&
    /// $0.utilization == event.to })`) silently picked the FIRST sample matching an event's
    /// (timestamp, utilization) pair, then assumed the array element immediately preceding it
    /// was the drop's origin. Two samples sharing that exact pair break both assumptions at
    /// once. Using `event.fromTimestamp` directly sidesteps the lookup (and the hazard)
    /// entirely.
    @Test @MainActor func duplicateSampleValuesDoNotMisassociateAnEvent() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        history.switchOrganization(UUID().uuidString)

        let stored = Date(timeIntervalSince1970: 1_786_984_799)
        let t0 = stored.addingTimeInterval(-500)   // BEFORE stored — the decoy's preceding sample
        let tFrom = stored.addingTimeInterval(100) // the credit's TRUE origin — AFTER stored
        let tTo = stored.addingTimeInterval(200)   // the credit's TRUE landing sample — AFTER stored

        // Two samples share the exact same (timestamp, utilization) = (tTo, 0) as the event's
        // (at, to) pair — the decoy at index 1 is immediately preceded by `t0` (before `stored`),
        // while the real preceding sample of the drop is `tFrom` (after `stored`).
        let event = UsageEvent(at: tTo, kind: .credit, from: 50, to: 0, fromTimestamp: tFrom)
        history.storage[identity] = WindowInstance(
            id: UUID(),
            storageIdentity: identity,
            resetsAt: stored,
            firstObservedAt: t0,
            samples: [
                UtilizationSample(utilization: 99, timestamp: t0),
                UtilizationSample(utilization: 0, timestamp: tTo),                       // decoy duplicate
                UtilizationSample(utilization: 50, timestamp: stored.addingTimeInterval(50)),
                UtilizationSample(utilization: 50, timestamp: tFrom),                    // true origin
                UtilizationSample(utilization: 0, timestamp: tTo),                       // true landing sample
            ],
            events: [event]
        )

        let entry = makeEntry(key: "five_hour", utilization: 0, resetsAt: stored.addingTimeInterval(duration))
        let newResetsAt = stored.addingTimeInterval(duration)
        let now = tTo.addingTimeInterval(55)
        let didReset = await history.detectAndHandleReset(entry: entry, newResetsAt: newResetsAt, at: now)

        #expect(didReset)
        // Both of the event's real endpoints (tFrom, tTo) are at/after `stored`, so this is a
        // genuine current-window credit. A value-matching lookup that mistakenly resolved the
        // decoy sample (preceded by `t0`, before `stored`) would have wrongly classified this as
        // a boundary-straddling drop and dropped it from both partitions.
        #expect(history.storage[identity]?.events == [event],
                "The duplicate sample must not cause this genuine current-window credit to be misclassified or dropped.")
    }

    /// A legacy event (`fromTimestamp == nil`, decoded from data written before this field
    /// existed) has an origin that can never be safely reconstructed, so it can never be
    /// checked for boundary-straddling the way a known-origin event can. Defect 1 (fixed):
    /// this used to mean the event was dropped from BOTH partitions at every ordinary
    /// boundary its window ever crossed, silently destroying a real historical marker forever.
    /// `event.at` is always known, so the event is partitioned by `at` alone instead — this
    /// test pins the corrected behavior using the exact real-world event from a genuine user
    /// history file (see UsageHistoryRealFixtureTests.swift for the raw-bytes round trip).
    @Test @MainActor func legacyEventWithUnknownOriginIsPartitionedByAtAloneAtABoundary() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        history.switchOrganization(UUID().uuidString)

        let stored = Date(timeIntervalSince1970: 1_786_984_799)
        let tBefore = stored.addingTimeInterval(-1800) // 30% sample well before the boundary
        let tAfter = stored.addingTimeInterval(2)       // 0% sample just after

        let legacyEvent = UsageEvent(at: tAfter, kind: .credit, from: 80, to: 0, fromTimestamp: nil)

        history.storage[identity] = WindowInstance(
            id: UUID(),
            storageIdentity: identity,
            resetsAt: stored,
            firstObservedAt: tBefore,
            samples: [
                UtilizationSample(utilization: 30, timestamp: tBefore),
                UtilizationSample(utilization: 0, timestamp: tAfter),
            ],
            events: [legacyEvent]
        )

        let entry = makeEntry(key: "five_hour", utilization: 0, resetsAt: stored.addingTimeInterval(duration))
        let newResetsAt = stored.addingTimeInterval(duration)
        let now = tAfter.addingTimeInterval(55)
        let didReset = await history.detectAndHandleReset(entry: entry, newResetsAt: newResetsAt, at: now)

        #expect(didReset)
        // `legacyEvent.at` (tAfter) is >= `stored`, so it is partitioned into the CURRENT
        // instance, not dropped and not archived.
        #expect(history.storage[identity]?.events == [legacyEvent],
                "A legacy event with unknown origin, whose `at` lands at/after the boundary, must be retained in the current partition, not dropped.")

        let archiveDir = history.archiveDirectory.appendingPathComponent(identity)
        let archiveFiles = try FileManager.default.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil)
        #expect(archiveFiles.count == 1)
        let decoded = try WindowInstanceCodec.decode(try Data(contentsOf: archiveFiles[0]))
        #expect(decoded.events.isEmpty,
                "The event's `at` is at/after the boundary, so it must not end up in the archived (prior) partition.")
    }

    /// Same shape as above, but the legacy event's `at` lands strictly BEFORE the boundary —
    /// it must be partitioned into the archived (prior) instance, not the retained current one.
    @Test @MainActor func legacyEventWithUnknownOriginBeforeBoundaryIsArchived() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        history.switchOrganization(UUID().uuidString)

        let stored = Date(timeIntervalSince1970: 1_786_984_799)
        let tBefore = stored.addingTimeInterval(-1800) // 30% sample well before the boundary
        let tEvent = stored.addingTimeInterval(-5)      // the drop itself, still before the boundary
        let tAfter = stored.addingTimeInterval(2)

        let legacyEvent = UsageEvent(at: tEvent, kind: .credit, from: 80, to: 30, fromTimestamp: nil)

        history.storage[identity] = WindowInstance(
            id: UUID(),
            storageIdentity: identity,
            resetsAt: stored,
            firstObservedAt: tBefore,
            samples: [
                UtilizationSample(utilization: 80, timestamp: tBefore),
                UtilizationSample(utilization: 30, timestamp: tEvent),
                UtilizationSample(utilization: 0, timestamp: tAfter),
            ],
            events: [legacyEvent]
        )

        let entry = makeEntry(key: "five_hour", utilization: 0, resetsAt: stored.addingTimeInterval(duration))
        let newResetsAt = stored.addingTimeInterval(duration)
        let now = tAfter.addingTimeInterval(55)
        let didReset = await history.detectAndHandleReset(entry: entry, newResetsAt: newResetsAt, at: now)

        #expect(didReset)
        #expect(history.storage[identity]?.events.isEmpty == true,
                "The event's `at` is before the boundary, so it must not survive in the current partition.")

        let archiveDir = history.archiveDirectory.appendingPathComponent(identity)
        let archiveFiles = try FileManager.default.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil)
        #expect(archiveFiles.count == 1)
        let decoded = try WindowInstanceCodec.decode(try Data(contentsOf: archiveFiles[0]))
        #expect(decoded.events == [legacyEvent],
                "A legacy event with unknown origin whose `at` precedes the boundary must be archived, not dropped.")
    }

    // MARK: - Defect 6: a dedup-skipped observation must not stale-date a credit event's origin

    /// `record()`'s dedup skip does not append a new sample (see `UsageHistory.lastObservedAt`'s
    /// doc comment), so the array's `last.timestamp` can lag the true most-recent same-value
    /// observation. If a genuine credit event's window boundary lies inside that lag window,
    /// using the stale array timestamp as `fromTimestamp` would make an event that is truly
    /// entirely on the CURRENT side of the boundary look like it straddles it — and get
    /// wrongly dropped by `partitionEvents`. This test drives `record()` through exactly that
    /// sequence (a recorded sample before the boundary, a same-value poll deduped shortly
    /// after the boundary, then a genuine drop) and asserts the event survives a subsequent
    /// genuine-boundary `detectAndHandleReset` call in the CURRENT partition.
    @Test @MainActor func dedupSkippedObservationDoesNotStaleDateACreditAcrossABoundary() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        history.switchOrganization(UUID().uuidString)

        let stored = Date(timeIntervalSince1970: 1_786_984_799)
        let t1 = stored.addingTimeInterval(-20) // recorded sample, util 50 — BEFORE the boundary
        let t2 = stored.addingTimeInterval(5)   // same value (50), deduped (gap from t1 is 25s <
                                                 // Constants.History.deduplicationInterval) — AFTER
                                                 // the boundary, but never appended to `samples`
        let t3 = stored.addingTimeInterval(40)  // genuine drop to 30 — AFTER the boundary

        let e1 = makeEntry(key: "five_hour", utilization: 50, resetsAt: stored)
        let e2 = makeEntry(key: "five_hour", utilization: 50, resetsAt: stored)
        let e3 = makeEntry(key: "five_hour", utilization: 30, resetsAt: stored)

        history.record(entries: [e1], at: t1)
        history.record(entries: [e2], at: t2)
        history.record(entries: [e3], at: t3)

        // Sanity check: t2 really was deduped away (never became its own sample).
        #expect(history.samples(for: e3).map(\.timestamp) == [t1, t3])

        let recordedEvents = history.storage[identity]?.events ?? []
        #expect(recordedEvents.count == 1)
        #expect(recordedEvents.first?.fromTimestamp == t2,
                "fromTimestamp must be the true most-recent same-value observation (t2), not the stale array-last timestamp (t1) that a deduped poll leaves behind.")

        let newResetsAt = stored.addingTimeInterval(duration)
        let entry = makeEntry(key: "five_hour", utilization: 30, resetsAt: newResetsAt)
        let now = t3.addingTimeInterval(60)
        let didReset = await history.detectAndHandleReset(entry: entry, newResetsAt: newResetsAt, at: now)

        #expect(didReset)
        // Both the event's true origin (t2) and landing (t3) are at/after `stored`, so it must
        // be retained in the CURRENT partition. Using the stale t1 as `fromTimestamp` would
        // have made this look like a straddle (t1 < stored, t3 >= stored) and dropped it.
        #expect(history.storage[identity]?.events == recordedEvents,
                "The event must survive in the current partition, not be wrongly dropped as a false straddle.")

        let archiveDir = history.archiveDirectory.appendingPathComponent(identity)
        let archiveFiles = try FileManager.default.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil)
        #expect(archiveFiles.count == 1)
        let decoded = try WindowInstanceCodec.decode(try Data(contentsOf: archiveFiles[0]))
        #expect(decoded.events.isEmpty, "The event must not end up archived either — it belongs entirely to the current window.")
    }

    // MARK: - Defect 2: a straddling event against a DERIVED boundary must be kept, not dropped

    /// The genuine-boundary branch's `boundary` (`stored`) is a PROVEN, previously-observed
    /// `resets_at` — a straddling event there really is the misclassified reset, so dropping it
    /// (see `serverLagAtBoundaryPartitionsSamplesAndDropsStraddlingCredit` above) is correct.
    /// The legacy-reconstruction branch's boundary (`windowStart = newResetsAt - duration`) is
    /// DERIVED, never itself observed — if that derivation is even slightly off, a legitimate
    /// credit whose origin and landing both truly belong to one window could be computed as
    /// straddling. Discarding on that unproven guess would be the worse error, so on a derived
    /// boundary a straddling event must be KEPT, assigned by its one certain timestamp (`at`),
    /// exactly as the legacy branch did before the two branches were unified.
    @Test @MainActor func legacyReconstructionKeepsStraddlingEventAssignedByAtRatherThanDropping() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        history.switchOrganization(UUID().uuidString)

        let windowStart = Date(timeIntervalSince1970: 1_786_984_799) // the DERIVED boundary
        let newResetsAt = windowStart.addingTimeInterval(duration)

        let tBeforeSample = windowStart.addingTimeInterval(-1800)
        let tAfterSample = windowStart.addingTimeInterval(1800)
        let tFrom = windowStart.addingTimeInterval(-10) // origin BEFORE the derived boundary
        let tTo = windowStart.addingTimeInterval(10)    // landing AFTER the derived boundary — straddles

        let straddlingEvent = UsageEvent(at: tTo, kind: .credit, from: 80, to: 30, fromTimestamp: tFrom)

        // No persisted resets_at — this is the legacy-reconstruction branch (DERIVED boundary),
        // never the genuine-boundary branch (which requires a previously-persisted `stored`).
        history.storage[identity] = WindowInstance(
            id: UUID(),
            storageIdentity: identity,
            resetsAt: nil,
            firstObservedAt: tBeforeSample,
            samples: [
                UtilizationSample(utilization: 80, timestamp: tBeforeSample),
                UtilizationSample(utilization: 30, timestamp: tAfterSample),
            ],
            events: [straddlingEvent]
        )

        let entry = makeEntry(key: "five_hour", utilization: 30, resetsAt: newResetsAt)
        let now = tAfterSample.addingTimeInterval(60)
        _ = await history.detectAndHandleReset(entry: entry, newResetsAt: newResetsAt, at: now)

        // Kept — assigned by `at` (tTo, after windowStart), never discarded on the unproven
        // derived boundary.
        #expect(history.storage[identity]?.events == [straddlingEvent],
                "A straddling event against a DERIVED (legacy-reconstruction) boundary must be kept, not discarded — the boundary itself is unproven.")

        let archiveDir = history.archiveDirectory.appendingPathComponent(identity)
        let archiveFiles = try FileManager.default.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil)
        #expect(archiveFiles.count == 1)
        let decoded = try WindowInstanceCodec.decode(try Data(contentsOf: archiveFiles[0]))
        #expect(decoded.events.isEmpty, "The event lands in CURRENT (by `at`), so it must not also appear archived.")
    }
}
