import Foundation
import Testing
@testable import ClaudeMonitor

/// Covers `DataCoordinator.switchToProfile` — the account-switch entry point. Two-profile setups
/// are built directly on the coordinator's `ProfileStore` (no legacy bridge involved), since the
/// menu switcher that will call this lands in batch 2.
@MainActor
@Suite struct ProfileSwitchTests {
    private func makeTwoProfileCoordinator(
        usage: MockUsageService
    ) throws -> (DataCoordinator, Profile, Profile) {
        let secrets = InMemorySecrets()
        let store = makeTestProfileStore(secrets: secrets, label: "switch")
        let a = try store.addProfile(name: "A", organizationId: UUID().uuidString, cookie: "cookie-a")
        let b = try store.addProfile(name: "B", organizationId: UUID().uuidString, cookie: "cookie-b")
        store.setActive(id: a.id)
        let coordinator = DataCoordinator(
            statusService: MockStatusService(),
            usageService: usage,
            systemIdleProvider: MockSystemIdleProvider(),
            pathMonitor: MockPathMonitor(),
            profileStore: store,
            usageHistory: UsageHistoryTestFixture().history
        )
        return (coordinator, a, b)
    }

    // MARK: - Switch keeps previous usage until the new poll (stable menu position)

    @Test func switchKeepsPreviousUsageUntilNewPoll() async throws {
        let mockUsage = MockUsageService()
        mockUsage.result = .success(TestFixtures.usage())
        let (coordinator, _, b) = try makeTwoProfileCoordinator(usage: mockUsage)

        await coordinator.refresh()
        #expect(coordinator.currentUsage != nil, "usage must be populated before the switch")

        coordinator.switchToProfile(id: b.id)
        // Deliberately NOT cleared: dropping to "Loading" would remove the usage rows/graph and make
        // the open dropdown shrink and jump. The next poll replaces the values in place.
        #expect(coordinator.currentUsage != nil)
        coordinator.pollTask?.cancel()
    }

    // MARK: - T4: scheduler reset on switch (no backoff/stale leak between accounts)

    @Test func switchResetsSchedulerSoBackoffDoesNotLeakBetweenAccounts() async throws {
        let mockUsage = MockUsageService()
        mockUsage.result = .failure(ServiceError.unexpectedStatus(500))
        let (coordinator, _, b) = try makeTwoProfileCoordinator(usage: mockUsage)

        for _ in 0..<Constants.Retry.failureThreshold {
            await coordinator.refresh()
        }
        #expect(coordinator.scheduler.isAnyServiceStale,
                "account A must be marked stale after reaching the failure threshold")

        coordinator.switchToProfile(id: b.id)
        #expect(!coordinator.scheduler.isAnyServiceStale,
                "switching accounts must reset the scheduler — A's stale/backoff state must not carry to B")
        #expect(coordinator.scheduler.usageState.consecutiveFailures == 0)
        coordinator.pollTask?.cancel()
    }

    // MARK: - no-op on same profile

    @Test func switchingToActiveProfileIsANoOp() async throws {
        let mockUsage = MockUsageService()
        mockUsage.result = .success(TestFixtures.usage())
        let (coordinator, a, _) = try makeTwoProfileCoordinator(usage: mockUsage)

        await coordinator.refresh()
        #expect(coordinator.currentUsage != nil)

        coordinator.switchToProfile(id: a.id)
        // Same profile -> no restart, no clearing.
        #expect(coordinator.currentUsage != nil)
    }
}
