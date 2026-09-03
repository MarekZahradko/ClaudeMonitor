import Foundation
import Testing
@testable import ClaudeMonitor

/// Defect 4/4-revised: quarantined files used to accumulate in `liveDirectory` forever — the
/// only removal path was the user's "Clear History", which erases ALL history, making genuine
/// recovery impossible in practice. `pruneQuarantinedFiles` (wired into `pruneArchives`) gives
/// them the same retention treatment archives already get, and `quarantinedFileCount` exposes
/// their existence/count for a future UI.
///
/// The quarantine moment is encoded in the FILENAME (`.corrupt_<timestamp>`), never read from a
/// filesystem attribute: a `setAttributes` mtime stamp can silently fail (read-only volume,
/// unsupported attribute, permission race), leaving the file's inherited mtime — typically the
/// ORIGINAL (possibly ancient) file's mtime — as the only clock, which could prune the file
/// almost immediately or make it immortal. These tests therefore construct filenames directly
/// rather than manipulating mtime.
@Suite @MainActor struct UsageHistoryQuarantineRetentionTests {

    @Test func oldTimestampedQuarantinedFileIsPrunedRecentOneSurvives() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        history.switchOrganization(UUID().uuidString)
        let fm = FileManager.default
        let liveDir = history.liveDirectory
        try fm.createDirectory(at: liveDir, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_786_984_799)
        let years = 2
        let cutoff = try #require(UsageHistory.retentionCutoff(years: years, now: now))
        let formatter = UsageHistory.archiveDateFormatter

        let oldStamp = formatter.string(from: cutoff.addingTimeInterval(-3600))
        let oldQuarantined = liveDir.appendingPathComponent("18000.dat.corrupt_\(oldStamp)")
        try Data([0xDE, 0xAD]).write(to: oldQuarantined)
        // Give it an arbitrary, unrelated mtime to prove pruning derives age from the filename,
        // never from the filesystem attribute.
        try fm.setAttributes([.modificationDate: now], ofItemAtPath: oldQuarantined.path)

        let recentStamp = formatter.string(from: cutoff.addingTimeInterval(3600))
        let recentQuarantined = liveDir.appendingPathComponent("604800.dat.corrupt_\(recentStamp)")
        try Data([0xBE, 0xEF]).write(to: recentQuarantined)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: recentQuarantined.path)

        let countBefore = await history.quarantinedFileCount()
        #expect(countBefore == 2)

        await history.pruneQuarantinedFiles(retentionYears: years, now: now)

        #expect(!fm.fileExists(atPath: oldQuarantined.path), "A quarantined file whose ENCODED timestamp is older than retention must be pruned.")
        #expect(fm.fileExists(atPath: recentQuarantined.path), "A quarantined file whose encoded timestamp is within retention must survive, regardless of its mtime.")

        let countAfter = await history.quarantinedFileCount()
        #expect(countAfter == 1)
    }

    @Test func oldShapeQuarantinedFileWithNoEncodedTimestampIsNeverPruned() async throws {
        // A file quarantined before this scheme existed (or otherwise unparseable) has unknown
        // age. Deleting it on a guess (e.g. its mtime) would be the destructive mistake this
        // scheme replaces, so it must survive regardless of how old its mtime looks.
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        history.switchOrganization(UUID().uuidString)
        let fm = FileManager.default
        let liveDir = history.liveDirectory
        try fm.createDirectory(at: liveDir, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_786_984_799)
        let years = 2
        let cutoff = try #require(UsageHistory.retentionCutoff(years: years, now: now))

        let plainOldShape = liveDir.appendingPathComponent("18000.dat.corrupt")
        try Data([0xDE, 0xAD]).write(to: plainOldShape)
        try fm.setAttributes([.modificationDate: cutoff.addingTimeInterval(-3600)], ofItemAtPath: plainOldShape.path)

        let collisionOldShape = liveDir.appendingPathComponent("604800.dat.corrupt-2")
        try Data([0xBE, 0xEF]).write(to: collisionOldShape)
        try fm.setAttributes([.modificationDate: cutoff.addingTimeInterval(-3600)], ofItemAtPath: collisionOldShape.path)

        await history.pruneQuarantinedFiles(retentionYears: years, now: now)

        #expect(fm.fileExists(atPath: plainOldShape.path), "An old-shape `.corrupt` file with no encoded timestamp has unknown age and must never be pruned.")
        #expect(fm.fileExists(atPath: collisionOldShape.path), "An old-shape `.corrupt-N` file with no encoded timestamp has unknown age and must never be pruned.")
    }

    @Test func pruneArchivesAlsoPrunesQuarantinedFiles() async throws {
        // `pruneArchives` is the existing, already-wired-up entry point (called at launch,
        // periodically, and after every detected boundary) — quarantine cleanup must not
        // require a new call site to remember to add.
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        history.switchOrganization(UUID().uuidString)
        let fm = FileManager.default
        let liveDir = history.liveDirectory
        try fm.createDirectory(at: liveDir, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_786_984_799)
        let years = 2
        let cutoff = try #require(UsageHistory.retentionCutoff(years: years, now: now))
        let oldStamp = UsageHistory.archiveDateFormatter.string(from: cutoff.addingTimeInterval(-3600))

        let oldQuarantined = liveDir.appendingPathComponent("18000.dat.corrupt_\(oldStamp)")
        try Data([0xDE, 0xAD]).write(to: oldQuarantined)

        await history.pruneArchives(retentionYears: years, now: now)

        #expect(!fm.fileExists(atPath: oldQuarantined.path))
    }

    @Test func quarantineEncodesTimestampInFilenameNotFilesystemAttribute() async throws {
        // The quarantine moment must be recoverable from the NAME alone — never depend on a
        // `setAttributes` call, which can silently fail. This drives the real `quarantine()`
        // path (via an undecodable legacy file) and asserts the resulting name parses to a
        // recent timestamp, then that a prune using "now" does not delete it.
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        history.switchOrganization(UUID().uuidString)
        let fm = FileManager.default
        let liveDir = history.liveDirectory
        try fm.createDirectory(at: liveDir, withIntermediateDirectories: true)

        // An undecodable legacy file whose own file-system age is already ancient.
        let legacyURL = liveDir.appendingPathComponent("18000.json")
        try Data([0xFF, 0x00, 0xDE, 0xAD]).write(to: legacyURL)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: legacyURL.path)

        let entry = makeEntry(key: "five_hour", utilization: 42, resetsAt: Date().addingTimeInterval(3600))
        history.record(entries: [entry], at: Date())
        await history.save() // quarantines the undecodable legacy file

        let files = try fm.contentsOfDirectory(at: liveDir, includingPropertiesForKeys: nil)
        let quarantinedURL = try #require(files.first { UsageHistory.isQuarantineFile($0) && $0.deletingPathExtension().lastPathComponent == "18000.json" })

        let encodedTimestamp = try #require(UsageHistory.quarantineTimestamp(quarantinedURL))
        #expect(encodedTimestamp.timeIntervalSinceNow > -60, "The encoded timestamp must reflect quarantine time, not the original file's ancient modification date.")

        // With the quarantine clock correctly encoded, a prune using "now" must not delete it,
        // even though its mtime (inherited from the ancient legacy file) says otherwise.
        await history.pruneQuarantinedFiles()
        #expect(fm.fileExists(atPath: quarantinedURL.path))
    }
}

/// Defect 5: a permanently failing `save()` (full disk, read-only volume, revoked sandbox
/// permission) used to fail completely silently, forever — with no signal that a whole
/// session's history was never persisted. `lastSaveSucceeded`/`persistenceFailingSince` expose
/// that state for a future UI to surface.
@Suite @MainActor struct UsageHistoryPersistenceFailureStateTests {

    @Test func successfulSaveReportsSuccessWithNoFailureClock() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        history.switchOrganization(UUID().uuidString)
        let entry = makeEntry(key: "five_hour", utilization: 42, resetsAt: Date().addingTimeInterval(3600))
        history.record(entries: [entry], at: Date())

        await history.save()

        #expect(history.lastSaveSucceeded)
        #expect(history.persistenceFailingSince == nil)
    }

    @Test func failingSaveSetsFailureStateAndClockOnlyOnce() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        history.switchOrganization(UUID().uuidString)
        let entry = makeEntry(key: "five_hour", utilization: 42, resetsAt: Date().addingTimeInterval(3600))
        history.record(entries: [entry], at: Date())

        let liveDir = history.liveDirectory
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: liveDir.path)
        defer {
            // Restore write permission unconditionally — see UnwritableDirectoryTests for why
            // this must never be skipped (it would wedge TestHistoryRoot's own cleanup sweep).
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: liveDir.path)
        }

        await history.save()
        #expect(!history.lastSaveSucceeded)
        let firstFailureTime = try #require(history.persistenceFailingSince)

        // A second consecutive failure must not reset the clock — it should still report
        // "failing since" the FIRST failure, not the most recent one.
        await history.save()
        #expect(!history.lastSaveSucceeded)
        #expect(history.persistenceFailingSince == firstFailureTime)
    }

    @Test func recoveringSaveClearsTheFailureClock() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        history.switchOrganization(UUID().uuidString)
        let entry = makeEntry(key: "five_hour", utilization: 42, resetsAt: Date().addingTimeInterval(3600))
        history.record(entries: [entry], at: Date())

        let liveDir = history.liveDirectory
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: liveDir.path)
        var restored = false
        defer {
            if !restored {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: liveDir.path)
            }
        }

        await history.save()
        #expect(!history.lastSaveSucceeded)
        #expect(history.persistenceFailingSince != nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: liveDir.path)
        restored = true

        await history.save()
        #expect(history.lastSaveSucceeded)
        #expect(history.persistenceFailingSince == nil, "A fully successful save must clear the failure clock.")
    }
}
