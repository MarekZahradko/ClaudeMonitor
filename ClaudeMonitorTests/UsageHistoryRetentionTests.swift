import Foundation
import Testing
@testable import ClaudeMonitor

/// Covers Task 1 (calendar-based retention + defensive clamping), Task 4 (would-delete count
/// computed without deleting), and Task 5 (archiving a window that vanished from the API).
/// Never adds teardown deletion — TestHistoryRoot preserves each run's data for post-mortem
/// debugging, only sweeping previous runs at startup.
///
/// Every test below fixes `now` to an explicit, hardcoded instant rather than `Date()`. This
/// suite previously computed cutoffs from the real wall clock, which both made results
/// dependent on the hour the suite happened to run AND hid a fixture logic bug (a "survivor"
/// archive was placed relative to the wrong cutoff and was, at certain unrelated real dates,
/// coincidentally on the wrong side of the boundary it was meant to test). A fixed `now`
/// makes every date arithmetic relationship in this file explicit and reviewable.
@Suite(.serialized) @MainActor struct UsageHistoryRetentionTests {
    /// Arbitrary fixed instant used everywhere `now` is needed in this suite, so no test's
    /// outcome can depend on the real date/time or timezone the suite executes in.
    private static let fixedNow: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
    }()

    // MARK: - Task 1: calendar-based cutoff

    @Test func retentionCutoffUsesCalendarYearsNotFixedSeconds() {
        // A leap-year-spanning span: from 2024-03-01 back 1 year crosses Feb 29, 2024.
        // A fixed 365-day approximation would land one day off; Calendar arithmetic must not.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2024, month: 3, day: 1, hour: 12))!
        let expectedCutoff = calendar.date(from: DateComponents(year: 2023, month: 3, day: 1, hour: 12))!

        let cutoff = UsageHistory.retentionCutoff(years: 1, now: now)
        #expect(cutoff == expectedCutoff)
    }

    @Test func archiveJustInsideRetentionSurvivesJustOutsideIsDeleted() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        let testOrgId = UUID().uuidString
        history.switchOrganization(testOrgId)
        let fm = FileManager.default
        let identityDir = archiveTestDirectory(baseDirectory: fixture.baseDirectory, orgId: testOrgId)
        try fm.createDirectory(at: identityDir, withIntermediateDirectories: true)
        let formatter = archiveDateFormatterForTests()

        let now = Self.fixedNow
        let years = 2
        let cutoff = UsageHistory.retentionCutoff(years: years, now: now)!

        let insideEnd = cutoff.addingTimeInterval(3600)
        let insideStart = insideEnd.addingTimeInterval(-18000)
        let insideURL = identityDir.appendingPathComponent("\(formatter.string(from: insideStart))_\(formatter.string(from: insideEnd)).\(Constants.History.windowInstanceFileExtension)")
        try Data().write(to: insideURL)

        let outsideEnd = cutoff.addingTimeInterval(-3600)
        let outsideStart = outsideEnd.addingTimeInterval(-18000)
        let outsideURL = identityDir.appendingPathComponent("\(formatter.string(from: outsideStart))_\(formatter.string(from: outsideEnd)).\(Constants.History.windowInstanceFileExtension)")
        try Data().write(to: outsideURL)

        await history.pruneArchives(retentionYears: years, now: now)

        #expect(fm.fileExists(atPath: insideURL.path), "Archive just inside retention must survive")
        #expect(!fm.fileExists(atPath: outsideURL.path), "Archive just outside retention must be deleted")
    }

    /// Documents and locks in the exact-boundary behaviour: production compares
    /// `entry.endDate < cutoff` to decide deletion, so a window whose end date is *exactly*
    /// the cutoff instant is NOT `< cutoff` and therefore SURVIVES — the cutoff instant itself
    /// is the oldest moment still kept. Only an end date strictly older than the cutoff
    /// (by even one second) is deleted.
    @Test func archiveExactlyAtCutoffSurvivesOneSecondOlderIsDeleted() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        let testOrgId = UUID().uuidString
        history.switchOrganization(testOrgId)
        let fm = FileManager.default
        let identityDir = archiveTestDirectory(baseDirectory: fixture.baseDirectory, orgId: testOrgId)
        try fm.createDirectory(at: identityDir, withIntermediateDirectories: true)
        let formatter = archiveDateFormatterForTests()

        let now = Self.fixedNow
        let years = 2
        let cutoff = UsageHistory.retentionCutoff(years: years, now: now)!

        func writeArchive(end: Date) throws -> URL {
            let start = end.addingTimeInterval(-18000)
            let url = identityDir.appendingPathComponent("\(formatter.string(from: start))_\(formatter.string(from: end)).\(Constants.History.windowInstanceFileExtension)")
            try Data().write(to: url)
            return url
        }

        let exactlyAtCutoff = try writeArchive(end: cutoff)
        let oneSecondOlder = try writeArchive(end: cutoff.addingTimeInterval(-1))

        await history.pruneArchives(retentionYears: years, now: now)

        #expect(fm.fileExists(atPath: exactlyAtCutoff.path), "An archive ending exactly at the cutoff instant must survive")
        #expect(!fm.fileExists(atPath: oneSecondOlder.path), "An archive one second older than the cutoff must be deleted")
    }

    // MARK: - Task 1: defensive clamping on read

    @Test func retentionYearsClampsCorruptOrAbsentValuesToDefault() {
        let suiteName = TestPreferencesRoot.makeSuiteName("UsageHistoryRetentionTests.clamp")
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removeObject(forKey: Constants.Preferences.historyRetentionYears)
        #expect(Constants.History.retentionYears(defaults: defaults) == Constants.History.defaultRetentionYears)

        for badValue in [0, -1, 100] {
            defaults.set(badValue, forKey: Constants.Preferences.historyRetentionYears)
            #expect(Constants.History.retentionYears(defaults: defaults) == Constants.History.defaultRetentionYears,
                    "Stored value \(badValue) must resolve to the default")
        }

        defaults.set(1, forKey: Constants.Preferences.historyRetentionYears)
        #expect(Constants.History.retentionYears(defaults: defaults) == 1)
        defaults.set(99, forKey: Constants.Preferences.historyRetentionYears)
        #expect(Constants.History.retentionYears(defaults: defaults) == 99)
    }

    @Test func clampRetentionYearsRestrictsToBounds() {
        #expect(Constants.History.clampRetentionYears(0) == Constants.History.minRetentionYears)
        #expect(Constants.History.clampRetentionYears(-50) == Constants.History.minRetentionYears)
        #expect(Constants.History.clampRetentionYears(1) == 1)
        #expect(Constants.History.clampRetentionYears(99) == 99)
        #expect(Constants.History.clampRetentionYears(100) == Constants.History.maxRetentionYears)
        #expect(Constants.History.clampRetentionYears(1000) == Constants.History.maxRetentionYears)
    }

    // MARK: - Task 4: would-delete count computed without deleting

    @Test func archivedWindowCountMatchesWhatWouldBeDeletedAndDeletesNothing() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        let testOrgId = UUID().uuidString
        history.switchOrganization(testOrgId)
        let fm = FileManager.default
        let identityDir = archiveTestDirectory(baseDirectory: fixture.baseDirectory, orgId: testOrgId)
        try fm.createDirectory(at: identityDir, withIntermediateDirectories: true)
        let formatter = archiveDateFormatterForTests()

        let now = Self.fixedNow
        let oldRetentionYears = 5
        let newRetentionYears = 1
        let oldCutoff = UsageHistory.retentionCutoff(years: oldRetentionYears, now: now)!
        let newCutoff = UsageHistory.retentionCutoff(years: newRetentionYears, now: now)!
        // Sanity check on the fixture's own premise: the 5-year cutoff is chronologically
        // BEFORE (older than) the 1-year cutoff, since a longer retention reaches further
        // into the past. Anything meant to "survive a decrease to 1 year" must be dated
        // AFTER newCutoff, not merely after oldCutoff — that was the bug this test caught.
        #expect(oldCutoff < newCutoff)

        // Two archives that survive today's (5-year) retention but would be deleted by a
        // decrease to 1 year (dated between oldCutoff and newCutoff); one archive that
        // survives both (dated after newCutoff, the more recent/stricter of the two cutoffs).
        func writeArchive(end: Date) throws -> URL {
            let start = end.addingTimeInterval(-18000)
            let url = identityDir.appendingPathComponent("\(formatter.string(from: start))_\(formatter.string(from: end)).\(Constants.History.windowInstanceFileExtension)")
            try Data().write(to: url)
            return url
        }

        let doomed1End = newCutoff.addingTimeInterval(-3600)
        let doomed2End = newCutoff.addingTimeInterval(-7200)
        let survivorEnd = newCutoff.addingTimeInterval(3600)
        let doomed1 = try writeArchive(end: doomed1End)
        let doomed2 = try writeArchive(end: doomed2End)
        let survivor = try writeArchive(end: survivorEnd)

        // Both doomed archives must actually be within the old (5-year) retention, and the
        // survivor must be within the new (1-year) retention too — otherwise this fixture
        // isn't testing what its names claim. Compare the END DATES used to construct each
        // archive, not the file URLs (a URL has no ordering relationship to a Date).
        #expect(doomed1End > oldCutoff && doomed2End > oldCutoff)
        #expect(survivorEnd > newCutoff)

        let count = await history.archivedWindowCount(retentionYears: newRetentionYears, now: now)
        #expect(count == 2, "Exactly the two archives older than the new cutoff should be counted")

        // Nothing must be deleted merely by counting.
        #expect(fm.fileExists(atPath: doomed1.path))
        #expect(fm.fileExists(atPath: doomed2.path))
        #expect(fm.fileExists(atPath: survivor.path))

        // Only an explicit prune with the new retention actually deletes.
        await history.pruneArchives(retentionYears: newRetentionYears, now: now)
        #expect(!fm.fileExists(atPath: doomed1.path))
        #expect(!fm.fileExists(atPath: doomed2.path))
        #expect(fm.fileExists(atPath: survivor.path))
    }

    // MARK: - Task 5: windows that vanish from the API

    @Test func windowAbsentBeyondThresholdIsArchived() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        history.switchOrganization(UUID().uuidString)
        let now = Self.fixedNow
        let duration: TimeInterval = 18000 // five_hour
        let entry = makeEntry(key: "five_hour", utilization: 40, resetsAt: now.addingTimeInterval(duration))
        history.record(entries: [entry], at: now)

        // First poll where the window is missing merely starts the clock.
        await history.archiveMissingWindows(currentIdentities: [], at: now)
        #expect(history.storage[entry.storageIdentity] != nil, "A single missing poll must not archive")

        // Still missing once the window's own duration has fully elapsed: unambiguous.
        let later = now.addingTimeInterval(duration + 1)
        await history.archiveMissingWindows(currentIdentities: [], at: later)
        #expect(history.storage[entry.storageIdentity] == nil, "Should be archived once unambiguously gone")

        let archiveDir = history.archiveDirectory.appendingPathComponent(entry.storageIdentity)
        let files = (try? FileManager.default.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil)) ?? []
        #expect(!files.isEmpty, "Missing window must be archived, not merely dropped")
    }

    @Test func windowMissingForOnlyASingleRefreshIsNotArchived() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        history.switchOrganization(UUID().uuidString)
        let now = Self.fixedNow
        let duration: TimeInterval = 18000
        let entry = makeEntry(key: "five_hour", utilization: 40, resetsAt: now.addingTimeInterval(duration))
        history.record(entries: [entry], at: now)

        // Missing for one poll, then reappears before the threshold elapses.
        await history.archiveMissingWindows(currentIdentities: [], at: now.addingTimeInterval(60))
        await history.archiveMissingWindows(currentIdentities: [entry.storageIdentity], at: now.addingTimeInterval(120))

        #expect(history.storage[entry.storageIdentity] != nil, "Window must not be archived once it reappears")

        // A later transient miss must restart the clock rather than reuse the earlier timestamp.
        await history.archiveMissingWindows(currentIdentities: [], at: now.addingTimeInterval(180))
        await history.archiveMissingWindows(currentIdentities: [], at: now.addingTimeInterval(180 + duration - 1))
        #expect(history.storage[entry.storageIdentity] != nil, "Must not archive before a full duration has elapsed since it went missing again")
    }

    /// Drives `DataCoordinator.refresh` itself (not `UsageHistory` directly) to verify the
    /// actual gating in `DataCoordinator+Refresh`: `archiveMissingWindows` is invoked only from
    /// the `.fresh` (successful, complete) usage-fetch branch, never on a failed fetch — see
    /// `refresh(now:)`'s `if case .fresh(let newUsage) = outcome` guard.
    @Test func archiveMissingWindowsOnlyRunsAfterSuccessfulFetchesNotFailedOnes() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        let testOrgId = UUID().uuidString
        history.switchOrganization(testOrgId)
        let now = Self.fixedNow
        let duration: TimeInterval = 18000 // five_hour
        let entry = makeEntry(key: "five_hour", utilization: 40, resetsAt: now.addingTimeInterval(duration))
        history.record(entries: [entry], at: now)

        let mockUsage = MockUsageService()
        mockUsage.result = .failure(ServiceError.unexpectedStatus(500))
        let (coordinator, _) = makeCoordinator(fixture: fixture, usage: mockUsage, testOrgId: testOrgId)
        let archiveDir = history.archiveDirectory.appendingPathComponent(entry.storageIdentity)

        // A failed fetch must never archive, even once `now` has advanced well past the
        // window's own duration.
        await coordinator.refresh(now: now.addingTimeInterval(duration + 1))
        #expect(history.storage[entry.storageIdentity] != nil, "A failed fetch must not archive a missing window")
        let filesAfterFailure = (try? FileManager.default.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil)) ?? []
        #expect(filesAfterFailure.isEmpty, "A failed fetch must not archive anything")

        // A successful fetch whose response genuinely omits the window: the first such poll
        // only starts the missing-window clock...
        mockUsage.result = .success(UsageResponse(entries: []))
        let firstMissingSuccess = now.addingTimeInterval(duration + 2)
        await coordinator.refresh(now: firstMissingSuccess)
        #expect(history.storage[entry.storageIdentity] != nil, "A single successful poll missing the window must not archive immediately")

        // ...and only archives once continuously absent, across successful fetches, for the
        // window's own full duration.
        await coordinator.refresh(now: firstMissingSuccess.addingTimeInterval(duration + 1))
        #expect(history.storage[entry.storageIdentity] == nil, "A window absent across successful fetches for a full duration must be archived")
        let filesAfterSuccess = (try? FileManager.default.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil)) ?? []
        #expect(!filesAfterSuccess.isEmpty, "Missing window must be archived once confirmed gone across successful fetches")
    }
}
