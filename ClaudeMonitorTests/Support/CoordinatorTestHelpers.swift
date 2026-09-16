import Foundation
@testable import ClaudeMonitor

/// Builds a `ProfileStore` backed by an isolated `UserDefaults` suite and the given in-memory
/// secret store, so no test ever touches the production preferences domain or the real encrypted
/// defaults.
@MainActor
func makeTestProfileStore(secrets: InMemorySecrets, label: String = "coord") -> ProfileStore {
    let defaults = UserDefaults(suiteName: TestPreferencesRoot.makeSuiteName(label))!
    return ProfileStore(
        defaults: defaults,
        loadSecret: { secrets.load($0) },
        saveSecret: { secrets.save($0, $1) },
        removeSecret: { secrets.remove($0) }
    )
}

@MainActor
func makeCoordinator(
    fixture: UsageHistoryTestFixture,
    status: any StatusFetching = MockStatusService(),
    usage: any UsageFetching = MockUsageService(),
    idle: any SystemIdleProviding = MockSystemIdleProvider(),
    path: (any PathMonitoring)? = nil,
    testOrgId: String = UUID().uuidString,
    credentials: [String: String]? = nil
) -> (DataCoordinator, String) {
    // Build an active profile directly from the credential pair. `credentials: [:]` (or an empty
    // cookie/org) means "no credentials present" — no profile is created, so `hasCredentials` is
    // false, matching a fresh install.
    let creds = credentials ?? [
        Constants.Keychain.cookieString: "test-cookie",
        Constants.Keychain.organizationId: testOrgId,
    ]
    let store = makeTestProfileStore(secrets: InMemorySecrets())
    if let cookie = creds[Constants.Keychain.cookieString],
       let orgId = creds[Constants.Keychain.organizationId],
       !cookie.isEmpty, !orgId.isEmpty,
       let profile = try? store.addProfile(name: "Test", organizationId: orgId, cookie: cookie) {
        store.setActive(id: profile.id)
    }

    let coordinator = DataCoordinator(
        statusService: status,
        usageService: usage,
        systemIdleProvider: idle,
        pathMonitor: path ?? MockPathMonitor(),
        profileStore: store,
        usageHistory: fixture.history
    )
    return (coordinator, testOrgId)
}
