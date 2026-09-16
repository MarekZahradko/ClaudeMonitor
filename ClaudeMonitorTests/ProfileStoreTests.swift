import Foundation
import Testing
@testable import ClaudeMonitor

/// In-memory stand-in for the encrypted trezor so tests never touch `UserDefaults.standard`
/// or the real `EncryptedDefaultsService`. `@MainActor` because `ProfileStore` is.
@MainActor
final class InMemorySecrets {
    var store: [String: String] = [:]
    func load(_ key: String) -> String? { store[key] }
    func save(_ key: String, _ value: String) -> Bool { store[key] = value; return true }
    func remove(_ key: String) { store[key] = nil }
}

@MainActor
@Suite struct ProfileStoreTests {
    /// A fresh isolated `UserDefaults` suite + empty secret store, wired into a `ProfileStore`.
    private func makeStore(
        secrets: InMemorySecrets = InMemorySecrets(),
        label: String = "profiles"
    ) -> (ProfileStore, UserDefaults, InMemorySecrets) {
        let suiteName = TestPreferencesRoot.makeSuiteName(label)
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = ProfileStore(
            defaults: defaults,
            loadSecret: { secrets.load($0) },
            saveSecret: { secrets.save($0, $1) },
            removeSecret: { secrets.remove($0) }
        )
        return (store, defaults, secrets)
    }

    // MARK: - Migration

    @Test func migratesLegacyCredentialsIntoProfileOne() {
        let secrets = InMemorySecrets()
        let orgId = UUID().uuidString
        secrets.store[Constants.Keychain.cookieString] = "legacy-cookie"
        secrets.store[Constants.Keychain.organizationId] = orgId

        let (store, defaults, _) = makeStore(secrets: secrets)

        #expect(store.profiles.count == 1)
        #expect(store.activeProfile?.organizationId == orgId)
        #expect(store.activeProfile?.name == Constants.Profiles.migratedProfileDefaultName)
        #expect(store.activeCookie == "legacy-cookie")
        // Registry key is now present -> migration marker set.
        #expect(defaults.object(forKey: Constants.Profiles.registryKey) != nil)
    }

    @Test func migrationKeepsLegacyKeysForDowngrade() {
        let secrets = InMemorySecrets()
        secrets.store[Constants.Keychain.cookieString] = "legacy-cookie"
        secrets.store[Constants.Keychain.organizationId] = UUID().uuidString

        _ = makeStore(secrets: secrets)

        #expect(secrets.store[Constants.Keychain.cookieString] == "legacy-cookie")
        #expect(secrets.store[Constants.Keychain.organizationId] != nil)
    }

    @Test func freshInstallWithNoLegacyMigratesToEmpty() {
        let (store, defaults, _) = makeStore()

        #expect(store.profiles.isEmpty)
        #expect(store.activeProfile == nil)
        // Marker still written, so a later empty state is never re-migrated.
        #expect(defaults.object(forKey: Constants.Profiles.registryKey) != nil)
    }

    @Test func doesNotReMigrateWhenRegistryAlreadyExists() {
        // A registry exists (empty) but stale legacy keys are still around: must NOT resurrect them.
        let secrets = InMemorySecrets()
        secrets.store[Constants.Keychain.cookieString] = "stale"
        secrets.store[Constants.Keychain.organizationId] = UUID().uuidString

        let suiteName = TestPreferencesRoot.makeSuiteName("noremigrate")
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(try! JSONEncoder().encode([Profile]()), forKey: Constants.Profiles.registryKey)

        let store = ProfileStore(
            defaults: defaults,
            loadSecret: { secrets.load($0) },
            saveSecret: { secrets.save($0, $1) },
            removeSecret: { secrets.remove($0) }
        )

        #expect(store.profiles.isEmpty)
        #expect(store.activeProfile == nil)
    }

    // MARK: - Add / active / cookie

    @Test func addProfileStoresItAndItsCookie() throws {
        let (store, _, _) = makeStore()
        let profile = try store.addProfile(name: "Work", organizationId: UUID().uuidString, cookie: "c1")

        #expect(store.profiles.contains(profile))
        #expect(store.cookie(for: profile) == "c1")
    }

    @Test func addDoesNotChangeActive() throws {
        let (store, _, _) = makeStore()
        #expect(store.activeProfile == nil)
        _ = try store.addProfile(name: "Work", organizationId: UUID().uuidString, cookie: "c1")
        // Adding a profile to an empty store leaves no active profile until the caller sets one.
        #expect(store.activeProfile == nil)
    }

    @Test func setActiveSelectsProfile() throws {
        let (store, _, _) = makeStore()
        let p = try store.addProfile(name: "Work", organizationId: UUID().uuidString, cookie: "c1")
        store.setActive(id: p.id)

        #expect(store.activeProfile == p)
        #expect(store.activeCookie == "c1")
    }

    @Test func setActiveIgnoresUnknownId() throws {
        let (store, _, _) = makeStore()
        _ = try store.addProfile(name: "Work", organizationId: UUID().uuidString, cookie: "c1")
        store.setActive(id: "does-not-exist")
        #expect(store.activeProfile == nil)
    }

    // MARK: - Duplicate org id

    @Test func rejectsDuplicateOrganizationId() throws {
        let (store, _, _) = makeStore()
        let orgId = UUID().uuidString
        _ = try store.addProfile(name: "Personal", organizationId: orgId, cookie: "c1")

        #expect(throws: ProfileStoreError.duplicateOrganization) {
            _ = try store.addProfile(name: "Work", organizationId: orgId, cookie: "c2")
        }
        #expect(store.profiles.count == 1)
    }

    // MARK: - Remove

    @Test func removeProfileDropsItAndItsCookie() throws {
        let (store, _, secrets) = makeStore()
        let p = try store.addProfile(name: "Work", organizationId: UUID().uuidString, cookie: "c1")
        store.setActive(id: p.id)

        store.removeProfile(id: p.id)

        #expect(store.profiles.isEmpty)
        #expect(store.activeProfile == nil)
        #expect(secrets.store[Constants.Profiles.cookieKey(profileId: p.id)] == nil)
    }

    @Test func removeActiveFallsBackToRemaining() throws {
        let (store, _, _) = makeStore()
        let a = try store.addProfile(name: "A", organizationId: UUID().uuidString, cookie: "c1")
        let b = try store.addProfile(name: "B", organizationId: UUID().uuidString, cookie: "c2")
        store.setActive(id: a.id)

        store.removeProfile(id: a.id)

        #expect(store.activeProfile == b)
    }

    // MARK: - Persistence & reconciliation

    @Test func profilesPersistAcrossInstances() throws {
        let secrets = InMemorySecrets()
        let suiteName = TestPreferencesRoot.makeSuiteName("persist")
        let defaults = UserDefaults(suiteName: suiteName)!

        let storeA = ProfileStore(
            defaults: defaults,
            loadSecret: { secrets.load($0) },
            saveSecret: { secrets.save($0, $1) },
            removeSecret: { secrets.remove($0) }
        )
        let p = try storeA.addProfile(name: "Work", organizationId: UUID().uuidString, cookie: "c1")
        storeA.setActive(id: p.id)

        let storeB = ProfileStore(
            defaults: defaults,
            loadSecret: { secrets.load($0) },
            saveSecret: { secrets.save($0, $1) },
            removeSecret: { secrets.remove($0) }
        )

        #expect(storeB.profiles == storeA.profiles)
        #expect(storeB.activeProfile == p)
    }

    // MARK: - Update

    @Test func updateProfileChangesNameOrgAndCookie() throws {
        let (store, _, _) = makeStore()
        let p = try store.addProfile(name: "Old", organizationId: UUID().uuidString, cookie: "c1")
        let newOrg = UUID().uuidString

        try store.updateProfile(id: p.id, name: "New", organizationId: newOrg, cookie: "c2")

        let updated = store.profiles.first { $0.id == p.id }
        #expect(updated?.name == "New")
        #expect(updated?.organizationId == newOrg)
        #expect(store.cookie(for: updated!) == "c2")
    }

    @Test func updateRejectsOrgUsedByAnotherProfile() throws {
        let (store, _, _) = makeStore()
        let orgB = UUID().uuidString
        let a = try store.addProfile(name: "A", organizationId: UUID().uuidString, cookie: "c1")
        _ = try store.addProfile(name: "B", organizationId: orgB, cookie: "c2")

        #expect(throws: ProfileStoreError.duplicateOrganization) {
            try store.updateProfile(id: a.id, name: "A", organizationId: orgB, cookie: "c1")
        }
    }

    @Test func updateAllowsKeepingOwnOrg() throws {
        let (store, _, _) = makeStore()
        let orgId = UUID().uuidString
        let p = try store.addProfile(name: "A", organizationId: orgId, cookie: "c1")

        try store.updateProfile(id: p.id, name: "A renamed", organizationId: orgId, cookie: "c2")

        #expect(store.profiles.first { $0.id == p.id }?.name == "A renamed")
        #expect(store.cookie(for: p) == "c2")
    }

    @Test func staleActiveIdReconcilesToFirstProfile() throws {
        let secrets = InMemorySecrets()
        let suiteName = TestPreferencesRoot.makeSuiteName("stale")
        let defaults = UserDefaults(suiteName: suiteName)!
        let profile = Profile(name: "Only", organizationId: UUID().uuidString)
        defaults.set(try! JSONEncoder().encode([profile]), forKey: Constants.Profiles.registryKey)
        defaults.set("ghost-id", forKey: Constants.Profiles.activeIdKey)

        let store = ProfileStore(
            defaults: defaults,
            loadSecret: { secrets.load($0) },
            saveSecret: { secrets.save($0, $1) },
            removeSecret: { secrets.remove($0) }
        )

        #expect(store.activeProfile == profile)
    }
}
