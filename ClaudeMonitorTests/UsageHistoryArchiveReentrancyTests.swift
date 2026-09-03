import Foundation
import Testing
@testable import ClaudeMonitor

/// Task: Defect 5 — `archiveWindow`'s post-`await` write of its `replacingWith:` replacement
/// must never resurrect data into a `storage` dict that a concurrent `clearAll()` or
/// `switchOrganization()` deliberately replaced while the archive's internal `Task.detached`
/// write was in flight. This is enforced structurally via a `generation` token that
/// `archiveWindow` captures before its `await` and re-checks immediately after, via
/// `applyArchiveReplacement`.
///
/// These tests exercise `applyArchiveReplacement` directly rather than racing real
/// `async let`/`Task.detached` scheduling against `clearAll()`/`switchOrganization()`: an
/// earlier version of this suite tried to force the interleaving with `async let` plus an
/// immediate `await clearAll()`, but that relies on the child task (archiveWindow) NOT
/// running to completion before the parent's next line executes — which Swift's cooperative
/// scheduler does not guarantee, especially when both are isolated to the same actor. In
/// practice that version was observed to let `archiveWindow` finish (including its
/// generation-gated write) before `clearAll()` ever ran, so the assertion wasn't reliably
/// exercising the race at all — a test that only sometimes hits the guard is close to
/// worthless for a correctness property like this one. Calling `applyArchiveReplacement`
/// directly with a deliberately-stale `capturedGeneration` pins the exact same guard
/// deterministically, with no scheduling dependency.
@Suite @MainActor struct UsageHistoryArchiveReentrancyTests {

    @Test func staleGenerationAfterClearAllIsRejected() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        let orgId = UUID().uuidString
        history.switchOrganization(orgId)

        let identity = "18000"
        let now = Date()
        // Simulate what archiveWindow does right before its internal Task.detached await:
        // capture the current generation.
        let capturedGeneration = history.generation

        // A clearAll() (e.g. the user hitting "Clear History" in Preferences) runs while the
        // archive's write is conceptually "in flight" — i.e. after generation was captured,
        // before the guarded write below.
        await history.clearAll()

        let replacement = WindowInstance(
            id: UUID(), storageIdentity: identity, resetsAt: nil,
            firstObservedAt: now, samples: [UtilizationSample(utilization: 0, timestamp: now)], events: []
        )
        let applied = history.applyArchiveReplacement(replacement, forIdentity: identity, capturedGeneration: capturedGeneration)

        #expect(!applied, "A generation captured before clearAll() must never be treated as current afterward.")
        #expect(history.storage[identity] == nil,
                "clearAll() must win: a stale-generation replacement must never resurrect data after storage was deliberately cleared.")
    }

    @Test func staleGenerationAfterSwitchOrganizationIsRejected() throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        let firstOrgId = UUID().uuidString
        let secondOrgId = UUID().uuidString
        history.switchOrganization(firstOrgId)

        let identity = "18000"
        let now = Date()
        let capturedGeneration = history.generation

        // A switchOrganization() (e.g. the user re-authenticating under a different account)
        // runs while the archive's write is conceptually "in flight".
        history.switchOrganization(secondOrgId)

        let replacement = WindowInstance(
            id: UUID(), storageIdentity: identity, resetsAt: nil,
            firstObservedAt: now, samples: [UtilizationSample(utilization: 0, timestamp: now)], events: []
        )
        let applied = history.applyArchiveReplacement(replacement, forIdentity: identity, capturedGeneration: capturedGeneration)

        #expect(!applied, "A generation captured before switchOrganization() must never be treated as current afterward.")
        #expect(history.storage[identity] == nil,
                "The first organization's stale-generation replacement must never land in the second organization's storage.")
    }

    @Test func matchingGenerationIsApplied() throws {
        // Sanity check on the other side of the guard: when nothing intervenes, the
        // replacement IS applied — the guard only rejects a STALE generation, not every write.
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        let orgId = UUID().uuidString
        history.switchOrganization(orgId)

        let identity = "18000"
        let now = Date()
        let capturedGeneration = history.generation

        let replacement = WindowInstance(
            id: UUID(), storageIdentity: identity, resetsAt: nil,
            firstObservedAt: now, samples: [UtilizationSample(utilization: 0, timestamp: now)], events: []
        )
        let applied = history.applyArchiveReplacement(replacement, forIdentity: identity, capturedGeneration: capturedGeneration)

        #expect(applied)
        #expect(history.storage[identity] == replacement)
    }
}
