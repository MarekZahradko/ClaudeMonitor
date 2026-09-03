import Foundation
import Testing
@testable import ClaudeMonitor

// MARK: - Task 6: legacy (v1) file deletion must never outrun a verified v2 write

@Suite @MainActor struct LegacyDeletionSafetyTests {

    @Test func legacyFileDeletedWhenItsOwnContentIsRepresentedInVerifiedV2Write() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        let orgId = UUID().uuidString
        history.switchOrganization(orgId)

        let entry = makeEntry(key: "five_hour", utilization: 42, resetsAt: Date().addingTimeInterval(3600))
        let now = Date()
        history.record(entries: [entry], at: now)

        // Simulate "legacy present, v2 absent": a pre-existing v1 file for this identity
        // whose content IS a subset of what's in memory (as it would be after a real load()
        // brought the legacy sample into memory before new samples were recorded on top).
        let liveDir = history.liveDirectory
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        let legacyURL = liveDir.appendingPathComponent("\(entry.storageIdentity).json")
        try UsageHistory.encodeCompact([UtilizationSample(utilization: 42, timestamp: now)]).write(to: legacyURL)
        #expect(FileManager.default.fileExists(atPath: legacyURL.path), "Setup: legacy file must exist before save()")

        await history.save()

        let v2URL = liveDir.appendingPathComponent("\(entry.storageIdentity).\(Constants.History.windowInstanceFileExtension)")
        #expect(FileManager.default.fileExists(atPath: v2URL.path), "current-format file must exist after save()")
        let decoded = try WindowInstanceCodec.decode(try Data(contentsOf: v2URL))
        #expect(decoded.samples.map(\.utilization) == [42], "current-format file must contain the samples that were in memory at save() time")

        #expect(!FileManager.default.fileExists(atPath: legacyURL.path),
                "Legacy file must be deleted once ITS OWN content is provably represented in the verified current-format file.")
    }

    @Test func legacyFileWithContentNotRepresentedInV2IsNeverDeleted() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        let orgId = UUID().uuidString
        history.switchOrganization(orgId)

        let entry = makeEntry(key: "five_hour", utilization: 42, resetsAt: Date().addingTimeInterval(3600))
        let now = Date()
        history.record(entries: [entry], at: now)

        // The legacy file's content genuinely differs from (is not a subset of) what's in
        // memory — e.g. a sample from before the app ever loaded this legacy file into
        // memory. Deleting it here would be silent, permanent data loss (Defect 1).
        let liveDir = history.liveDirectory
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        let legacyURL = liveDir.appendingPathComponent("\(entry.storageIdentity).json")
        try "[[0,1]]".data(using: .utf8)!.write(to: legacyURL)

        await history.save()

        #expect(FileManager.default.fileExists(atPath: legacyURL.path),
                "A legacy file whose own content is NOT represented in the v2 file must be preserved, never deleted.")
    }

    @Test func undecodableLegacyFileIsQuarantinedNeverDeleted() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        let orgId = UUID().uuidString
        history.switchOrganization(orgId)

        let entry = makeEntry(key: "five_hour", utilization: 42, resetsAt: Date().addingTimeInterval(3600))
        history.record(entries: [entry], at: Date())

        // A legacy file that cannot be decoded at all (garbage bytes, not JSON, not LZMA) —
        // this is the confirmed Defect-1 loss path: the old code's self-check against
        // in-memory state was trivially true regardless of what this file actually held.
        let liveDir = history.liveDirectory
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        let legacyURL = liveDir.appendingPathComponent("\(entry.storageIdentity).json")
        try Data([0xFF, 0x00, 0xDE, 0xAD, 0xBE, 0xEF]).write(to: legacyURL)

        await history.save()

        #expect(!FileManager.default.fileExists(atPath: legacyURL.path),
                "The undecodable legacy file must no longer sit at its original path (it was quarantined, not left in place).")
        let siblings = try FileManager.default.contentsOfDirectory(at: liveDir, includingPropertiesForKeys: nil)
        let quarantinedURL = try #require(siblings.first {
            UsageHistory.isQuarantineFile($0) && $0.deletingPathExtension().lastPathComponent == legacyURL.lastPathComponent
        })
        #expect(FileManager.default.fileExists(atPath: quarantinedURL.path),
                "The undecodable legacy file's bytes must be preserved under a .corrupt_<timestamp> suffix, never deleted.")
    }

    @Test func partiallyMalformedLegacyJSONFailsWholeDecodeRatherThanDroppingEntries() {
        // A malformed legacy file must surface as a total decode failure, not silently lose
        // just the unparsable entries while keeping the rest (Defect 1's second loss path).
        let malformed = Data("[[0,1],[\"not-a-number\",2],[120,3]]".utf8)
        #expect(UsageHistory.decodeCompact(malformed) == nil,
                "A single malformed [epoch,util] pair must fail the entire decode.")
    }

    // MARK: - Defect 4: legacy-content containment must be multiset-, not set-, aware

    @Test func legacyFileWithDuplicateKeyNotFullyCoveredByASingleVerifiedSampleIsPreserved() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        let orgId = UUID().uuidString
        history.switchOrganization(orgId)

        let entry = makeEntry(key: "five_hour", utilization: 42, resetsAt: Date().addingTimeInterval(3600))
        let now = Date()
        history.record(entries: [entry], at: now)

        // The legacy file claims the SAME (utilization, epoch-second) key TWICE; the
        // freshly-written current-format file (built from in-memory `storage`, which has only
        // ONE sample) can only ever back one occurrence of that key. A `Set`-based
        // containment check would mark the key "seen" after the first match and wrongly
        // consider the second legacy entry covered too, deleting a legacy file that actually
        // held one more sample than what's provably represented in the verified read-back.
        let liveDir = history.liveDirectory
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        let legacyURL = liveDir.appendingPathComponent("\(entry.storageIdentity).json")
        let duplicated = [
            UtilizationSample(utilization: 42, timestamp: now),
            UtilizationSample(utilization: 42, timestamp: now),
        ]
        try UsageHistory.encodeCompact(duplicated).write(to: legacyURL)

        await history.save()

        #expect(FileManager.default.fileExists(atPath: legacyURL.path),
                "A legacy file claiming a key TWICE must not be deleted when the verified current-format file can only back it ONCE.")
    }

    // "Legacy present, current-format write fails -> legacy must survive" is guaranteed
    // structurally, not just empirically: in saveInstance() (UsageHistory+Persistence.swift),
    // `try data.write(to: url, options: .atomic)` is followed immediately by `return` inside
    // its own `catch`, and the legacy-deletion code is textually and control-flow-wise AFTER
    // that entire do/catch block — so a thrown write error provably cannot reach the
    // legacy-deletion step; Swift's `try`/`catch` makes this a compile-time-enforced
    // ordering, not a race that could be observed to go the other way. `saveInstance` no
    // longer traps on that path either (see Defect 3 below), so the write-failure case itself
    // is now directly testable — see `UnwritableDirectoryTests`.

    // MARK: - Defect 1: clearAll()/save() quarantine handling must be deliberate, not incidental

    @Test func saveOrphanSweepPreservesPreviouslyQuarantinedFile() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        let orgId = UUID().uuidString
        history.switchOrganization(orgId)

        let liveDir = history.liveDirectory
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        // A file quarantined on some earlier run: stripping its `.corrupt` suffix yields
        // "18000.json", whose derived "identity" ("18000.json") never matches a real
        // storageIdentity ("18000") — so without the quarantine exclusion, save()'s "orphaned
        // identity" sweep would delete it on this very pass. `storage` is empty, so there is
        // no active identity to protect it any other way.
        let quarantinedURL = liveDir.appendingPathComponent("18000.json.corrupt")
        try Data([0xDE, 0xAD]).write(to: quarantinedURL)

        await history.save()

        #expect(FileManager.default.fileExists(atPath: quarantinedURL.path),
                "save()'s background orphan sweep must never delete a quarantined file.")
    }

    @Test func clearAllDeletesEverythingIncludingQuarantinedFiles() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        let orgId = UUID().uuidString
        history.switchOrganization(orgId)

        let liveDir = history.liveDirectory
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        let quarantinedURL = liveDir.appendingPathComponent("18000.json.corrupt")
        try Data([0xDE, 0xAD]).write(to: quarantinedURL)

        await history.clearAll()

        #expect(!FileManager.default.fileExists(atPath: quarantinedURL.path),
                "clearAll() is the user's explicit \"Clear History\" action — it must erase quarantined files too, unlike save()'s background sweep above.")
    }
}

// MARK: - Defect 3: environmental write failures must never trap the process

@Suite @MainActor struct UnwritableDirectoryTests {

    @Test func unwritableLiveDirectoryDoesNotCrashAndPreservesInMemoryData() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        let orgId = UUID().uuidString
        history.switchOrganization(orgId)

        let entry = makeEntry(key: "five_hour", utilization: 42, resetsAt: Date().addingTimeInterval(3600))
        history.record(entries: [entry], at: Date())

        let liveDir = history.liveDirectory
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        // Remove write permission on the live directory itself so creating a file inside it
        // fails — simulating a full disk, a read-only/disconnected volume, or revoked
        // sandbox/TCC permission. Now that saveInstance() no longer calls assertionFailure()
        // on a write failure (Defect 3), this is directly testable.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: liveDir.path)
        defer {
            // Restore write permission unconditionally: a directory left read-only by this
            // test must never be able to wedge TestHistoryRoot's own cleanup sweep, which
            // already has to defend against exactly this failure mode (see its doc comment).
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: liveDir.path)
        }

        await history.save()

        #expect(history.storage[entry.storageIdentity]?.samples.map(\.utilization) == [42],
                "A write failure must never lose in-memory data.")
        let url = liveDir.appendingPathComponent("\(entry.storageIdentity).\(Constants.History.windowInstanceFileExtension)")
        #expect(!FileManager.default.fileExists(atPath: url.path),
                "Sanity check: the directory really was unwritable, so no file should have been created.")
    }
}
