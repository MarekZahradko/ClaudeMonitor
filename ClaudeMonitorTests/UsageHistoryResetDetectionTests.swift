import Foundation
import Testing
@testable import ClaudeMonitor

@Suite struct ResetDetectionTests {

    // MARK: - Task 1: genuine boundary requires BOTH a forward move AND that the old
    // reset moment has actually passed.

    @Test @MainActor func forwardMoveWithNowPastStoredIsGenuineBoundaryAndArchives() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        history.switchOrganization(UUID().uuidString)

        let now = Date()
        let resetsAt = now.addingTimeInterval(3600)
        let entry = makeEntry(key: "five_hour", utilization: 42, resetsAt: resetsAt)
        history.record(entries: [entry], at: now)
        #expect(history.samples(for: entry).count == 1)

        let newResetsAt = resetsAt.addingTimeInterval(300)
        let didReset = await history.detectAndHandleReset(
            entry: makeEntry(key: "five_hour", utilization: 0, resetsAt: newResetsAt),
            newResetsAt: newResetsAt,
            at: resetsAt.addingTimeInterval(10) // now is past the old resetsAt
        )
        #expect(didReset)
        #expect(history.samples(for: makeEntry(key: "five_hour", utilization: 0, resetsAt: newResetsAt)).isEmpty)
    }

    @Test @MainActor func forwardMoveWithNowBeforeStoredIsDriftNotABoundary() async {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        let now = Date()
        let resetsAt = now.addingTimeInterval(3600)
        let entry = makeEntry(key: "five_hour", utilization: 42, resetsAt: resetsAt)
        history.record(entries: [entry], at: now)

        // Forward move, but the old window (resetsAt) has NOT ended yet — this is drift,
        // not a genuine boundary. Same instance, resetsAt updated, samples preserved.
        let newResetsAt = resetsAt.addingTimeInterval(300)
        let didReset = await history.detectAndHandleReset(
            entry: makeEntry(key: "five_hour", utilization: 42, resetsAt: newResetsAt),
            newResetsAt: newResetsAt,
            at: now // well before resetsAt
        )
        #expect(!didReset)
        #expect(history.samples(for: entry).count == 1)
        #expect(history.storage[entry.storageIdentity]?.resetsAt == newResetsAt)
    }

    @Test @MainActor func jitterWithinToleranceKeepsSameInstance() async {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        let now = Date()
        let resetsAt = now.addingTimeInterval(3600)
        let entry = makeEntry(key: "five_hour", utilization: 42, resetsAt: resetsAt)
        history.record(entries: [entry], at: now)

        let newResetsAt = resetsAt.addingTimeInterval(30)
        let didReset = await history.detectAndHandleReset(
            entry: makeEntry(key: "five_hour", utilization: 42, resetsAt: newResetsAt),
            newResetsAt: newResetsAt
        )
        #expect(!didReset)
        #expect(history.samples(for: entry).count == 1)
    }

    @Test @MainActor func backwardMoveKeepsSameInstanceAndNeverArchives() async {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        let now = Date()
        let resetsAt = now.addingTimeInterval(3600)
        let entry = makeEntry(key: "five_hour", utilization: 42, resetsAt: resetsAt)
        history.record(entries: [entry], at: now)

        let newResetsAt = resetsAt.addingTimeInterval(-300)
        let didReset = await history.detectAndHandleReset(
            entry: makeEntry(key: "five_hour", utilization: 42, resetsAt: newResetsAt),
            newResetsAt: newResetsAt
        )
        #expect(!didReset)
        #expect(history.samples(for: entry).count == 1)
    }

    @Test @MainActor func nilResetsAtDoesNotClearOrChangeStoredResetsAt() async {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        let now = Date()
        let entry = makeEntry(key: "five_hour", utilization: 42, resetsAt: nil)
        history.record(entries: [entry], at: now)

        let didReset = await history.detectAndHandleReset(
            entry: makeEntry(key: "five_hour", utilization: 0, resetsAt: nil),
            newResetsAt: nil
        )
        #expect(!didReset)
        #expect(history.samples(for: entry).count == 1)
    }

    // MARK: - Task 2: stored == nil (no persisted boundary state)

    @Test @MainActor func unverifiedNilStoredResetsAtWithEmptySamplesIsAdopted() async {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        let now = Date()
        let entry = makeEntry(key: "five_hour", utilization: 42, resetsAt: nil)
        // First observation establishes the instance with resetsAt=nil and no samples yet
        // (record() hasn't run for this identity), matching a freshly-created instance.
        history.storage[entry.storageIdentity] = WindowInstance(
            id: UUID(), storageIdentity: entry.storageIdentity, resetsAt: nil,
            firstObservedAt: now, samples: [], events: []
        )

        let newResetsAt = now.addingTimeInterval(3600)
        let didReset = await history.detectAndHandleReset(
            entry: makeEntry(key: "five_hour", utilization: 42, resetsAt: newResetsAt),
            newResetsAt: newResetsAt
        )
        #expect(!didReset)
        #expect(history.storage[entry.storageIdentity]?.resetsAt == newResetsAt)
    }

    @Test @MainActor func unverifiedNilStoredResetsAtWithSamplesInsideCurrentWindowIsRetainedNotArchived() async {
        // Legacy data whose sole sample already falls inside the window implied by the
        // freshly observed resets_at: it must be RETAINED, not discarded as an "unknown
        // prior window" (see UsageHistoryLegacyReconstructionTests for the full corpus of
        // Task 1 scenarios — this test only guards the historical regression at this call site).
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        history.switchOrganization(UUID().uuidString)
        let now = Date()
        let entry = makeEntry(key: "five_hour", utilization: 95, resetsAt: nil)
        // Simulates legacy/restored data: samples present, but no persisted resets_at.
        history.record(entries: [entry], at: now)
        #expect(history.samples(for: entry).count == 1)

        // newResetsAt chosen so windowStart (newResetsAt - 18000) is well before `now`,
        // i.e. the lone sample falls inside the reconstructed current window.
        let newResetsAt = now.addingTimeInterval(3600)
        let didReset = await history.detectAndHandleReset(
            entry: makeEntry(key: "five_hour", utilization: 3, resetsAt: newResetsAt),
            newResetsAt: newResetsAt
        )
        #expect(!didReset, "No prior partition exists, so no archive is written.")
        #expect(history.storage[entry.storageIdentity]?.samples.count == 1)
        #expect(history.storage[entry.storageIdentity]?.samples.first?.utilization == 95)
        #expect(history.storage[entry.storageIdentity]?.resetsAt == newResetsAt)

        let archiveDir = history.archiveDirectory.appendingPathComponent(entry.storageIdentity)
        let archiveFiles = (try? FileManager.default.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil)) ?? []
        #expect(archiveFiles.isEmpty, "Nothing precedes windowStart, so nothing is archived.")
    }

    // MARK: - Defect 2: the GENUINE-boundary branch must report `false` when nothing archives

    /// The `>=` inclusivity rule can put every sample of a genuine boundary on the NEW side
    /// (an empty prior partition) — e.g. when a window's only recorded sample happens to land
    /// exactly at `stored`. Before the fix, the genuine-boundary branch of
    /// `detectAndHandleReset` returned `true` unconditionally whenever `resets_at` moved
    /// forward past tolerance, even though `archiveWindow` silently declined to write anything
    /// (its `!instance.samples.isEmpty` guard fails on an empty prior partition). That `true`
    /// flows into `DataCoordinator`'s critical-reset trigger, so this could fire a user-visible
    /// "critical reset" animation for a boundary that archived no history at all. This is the
    /// GENUINE-boundary counterpart of `unverifiedNilStoredResetsAtWithSamplesInsideCurrentWindowIsRetainedNotArchived`
    /// above, which already covered the same empty-prior-partition shape for the legacy branch.
    @Test @MainActor func genuineBoundaryWithEmptyPriorPartitionArchivesNothingAndReturnsFalse() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        history.switchOrganization(UUID().uuidString)

        let identity = "18000"
        let stored = Date(timeIntervalSince1970: 1_786_984_799)
        // The lone sample lands EXACTLY at `stored` — under the `>=` inclusivity rule it
        // belongs to the NEW instance, so the prior partition is empty even though this is
        // otherwise a textbook genuine boundary (forward move past tolerance, old reset passed).
        history.storage[identity] = WindowInstance(
            id: UUID(), storageIdentity: identity, resetsAt: stored,
            firstObservedAt: stored, samples: [UtilizationSample(utilization: 0, timestamp: stored)], events: []
        )

        let newResetsAt = stored.addingTimeInterval(18000)
        let entry = makeEntry(key: "five_hour", utilization: 0, resetsAt: newResetsAt)
        let didReset = await history.detectAndHandleReset(entry: entry, newResetsAt: newResetsAt, at: stored.addingTimeInterval(1))

        #expect(!didReset, "Nothing was archived (the prior partition is empty), so this must not report a genuine boundary.")
        #expect(history.storage[identity]?.samples.count == 1, "The lone sample is retained in the new instance.")
        #expect(history.storage[identity]?.resetsAt == newResetsAt)

        let archiveDir = history.archiveDirectory.appendingPathComponent(identity)
        let archiveFiles = (try? FileManager.default.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil)) ?? []
        #expect(archiveFiles.isEmpty, "Nothing should be archived when the prior partition is empty.")
    }
}
