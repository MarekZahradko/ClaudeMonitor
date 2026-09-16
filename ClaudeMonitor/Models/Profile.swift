import Foundation

/// One named claude.ai account the user monitors. `organizationId` (and the name) are not
/// sensitive and live in the plaintext registry; the account's session cookie is stored
/// separately in the encrypted trezor under `Constants.Profiles.cookieKey(profileId:)`.
struct Profile: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var organizationId: String

    init(id: String = UUID().uuidString, name: String, organizationId: String) {
        self.id = id
        self.name = name
        self.organizationId = organizationId
    }
}

enum ProfileStoreError: Error, Equatable {
    /// A profile already exists with the same organization id. Two profiles sharing an org id
    /// would share one on-disk history directory (history is keyed by org id, not profile id),
    /// and switching between them would not partition data correctly — so it is rejected up front.
    case duplicateOrganization
    case saveFailed
}

/// Owns the list of profiles and which one is active, plus each profile's cookie in the encrypted
/// trezor. Registry (ids, names, org ids) lives in plaintext `UserDefaults`; cookies never do.
///
/// All storage access is injectable so tests run against an isolated `UserDefaults` suite and an
/// in-memory cookie store, never the production domain or the real encrypted defaults.
@MainActor
final class ProfileStore {
    private let defaults: UserDefaults
    private let loadSecret: (String) -> String?
    private let saveSecret: (String, String) -> Bool
    private let removeSecret: (String) -> Void

    private(set) var profiles: [Profile]
    private(set) var activeId: String?

    init(
        defaults: UserDefaults = .standard,
        loadSecret: @escaping (String) -> String? = { EncryptedDefaultsService.load(key: $0) },
        saveSecret: @escaping (String, String) -> Bool = { EncryptedDefaultsService.save(key: $0, value: $1) },
        removeSecret: @escaping (String) -> Void = { EncryptedDefaultsService.remove(key: $0) }
    ) {
        self.defaults = defaults
        self.loadSecret = loadSecret
        self.saveSecret = saveSecret
        self.removeSecret = removeSecret

        if let data = defaults.data(forKey: Constants.Profiles.registryKey),
           let decoded = try? JSONDecoder().decode([Profile].self, from: data) {
            profiles = decoded
        } else {
            profiles = []
        }
        activeId = defaults.string(forKey: Constants.Profiles.activeIdKey)

        migrateLegacyCredentialsIfNeeded()
        reconcileActiveId()
    }

    /// The active profile, or nil if none is set / the stored id is stale.
    var activeProfile: Profile? {
        guard let activeId else { return nil }
        return profiles.first { $0.id == activeId }
    }

    /// The active profile's session cookie from the encrypted trezor.
    var activeCookie: String? {
        guard let activeProfile else { return nil }
        return loadSecret(Constants.Profiles.cookieKey(profileId: activeProfile.id))
    }

    func cookie(for profile: Profile) -> String? {
        loadSecret(Constants.Profiles.cookieKey(profileId: profile.id))
    }

    /// Adds a new profile and its cookie. Rejects a duplicate org id. Does NOT change the active
    /// profile — the caller decides whether to switch to it.
    @discardableResult
    func addProfile(name: String, organizationId: String, cookie: String) throws -> Profile {
        guard !profiles.contains(where: { $0.organizationId == organizationId }) else {
            throw ProfileStoreError.duplicateOrganization
        }
        let profile = Profile(name: name, organizationId: organizationId)
        guard saveSecret(Constants.Profiles.cookieKey(profileId: profile.id), cookie) else {
            throw ProfileStoreError.saveFailed
        }
        profiles.append(profile)
        persist()
        return profile
    }

    /// Updates an existing profile's name, org, and cookie. Rejects an org id already used by a
    /// *different* profile. No-op for an unknown id.
    func updateProfile(id: String, name: String, organizationId: String, cookie: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        guard !profiles.contains(where: { $0.id != id && $0.organizationId == organizationId }) else {
            throw ProfileStoreError.duplicateOrganization
        }
        guard saveSecret(Constants.Profiles.cookieKey(profileId: id), cookie) else {
            throw ProfileStoreError.saveFailed
        }
        var updated = profiles[index]
        updated.name = name
        updated.organizationId = organizationId
        profiles[index] = updated
        persist()
    }

    /// Removes a profile and its cookie. Clears the active id if it pointed at this profile.
    /// History on disk (keyed by org id) is intentionally left untouched here — deleting it is a
    /// separate, explicit user choice handled by the UI.
    func removeProfile(id: String) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        removeSecret(Constants.Profiles.cookieKey(profileId: profile.id))
        profiles.removeAll { $0.id == id }
        if activeId == id {
            activeId = profiles.first?.id
        }
        persist()
    }

    /// Sets the active profile. No-op for an unknown id.
    func setActive(id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeId = id
        persist()
    }

    // MARK: - Migration

    /// On first launch after upgrading from a pre-profiles build, synthesizes "profile 1" from the
    /// single legacy credential set so the user keeps their account and — because the profile
    /// carries the same org id — their existing on-disk history directory, with zero history loss.
    ///
    /// Idempotent: keyed off the *presence* of the registry key, so it runs exactly once. Legacy
    /// keys are copied, never deleted, so a downgrade to the old build still works.
    private func migrateLegacyCredentialsIfNeeded() {
        guard defaults.object(forKey: Constants.Profiles.registryKey) == nil else { return }

        if let cookie = loadSecret(Constants.Keychain.cookieString),
           let orgId = loadSecret(Constants.Keychain.organizationId),
           !cookie.isEmpty, !orgId.isEmpty {
            let profile = Profile(name: Constants.Profiles.migratedProfileDefaultName, organizationId: orgId)
            if saveSecret(Constants.Profiles.cookieKey(profileId: profile.id), cookie) {
                profiles = [profile]
                activeId = profile.id
            }
        }
        persist()
    }

    /// Keeps `activeId` pointing at a profile that actually exists: if it is nil or stale, fall back
    /// to the first profile (or nil when there are none).
    private func reconcileActiveId() {
        if activeId == nil || !profiles.contains(where: { $0.id == activeId }) {
            activeId = profiles.first?.id
            persist()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Constants.Profiles.registryKey)
        }
        if let activeId {
            defaults.set(activeId, forKey: Constants.Profiles.activeIdKey)
        } else {
            defaults.removeObject(forKey: Constants.Profiles.activeIdKey)
        }
    }
}
