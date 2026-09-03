import Foundation

extension UsageHistory {
    /// Case-insensitive suffix match (Defect 6): a `.JSON.LZMA` file (or any other-cased
    /// variant) must be recognized identically to `.json.lzma` everywhere a legacy-archive
    /// suffix is checked — both when deciding whether to migrate it and when deciding whether
    /// it's visible to retention — so it can never end up invisible to both (and therefore
    /// inert forever, neither migrated nor ever deleted).
    nonisolated static func hasSuffixCaseInsensitive(_ name: String, _ suffix: String) -> Bool {
        name.lowercased().hasSuffix(suffix.lowercased())
    }

    /// Fixed-format formatter for archive/quarantine FILENAMES — machine-readable, never shown
    /// to the user.
    ///
    /// `locale` must be pinned to `en_US_POSIX` and must never be removed. A `DateFormatter`
    /// with no explicit locale falls back to `Locale.current`, which governs the CALENDAR and
    /// the NUMBERING SYSTEM even when `dateFormat` is set explicitly. Two distinct failures
    /// follow, and the second destroys data:
    ///
    /// 1. Under a locale with non-ASCII digits, `date(from:)` fails on a previously-written
    ///    name. `collectArchiveFiles` skips unparseable names, so that archive becomes
    ///    permanently invisible to retention — never counted, never pruned.
    /// 2. Under a non-Gregorian calendar (e.g. Thai Buddhist), the same literal digits PARSE
    ///    SUCCESSFULLY into a completely different absolute date — Buddhist 2026 is Gregorian
    ///    1483. `retentionCutoff` uses an explicit Gregorian calendar, so that archive compares
    ///    as centuries old and is deleted on the next prune. The user's history is their only
    ///    copy; this is silent, immediate, irreversible loss.
    ///
    /// `timeZone` is pinned for the same reason: the `Z` suffix in the format is a literal, so
    /// the written instant must actually be UTC.
    nonisolated static let archiveDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmm'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Collapses runs of consecutive equal-utilization samples to their first and last
    /// member — lossless under step and linear interpolation, since the dropped points are
    /// collinear. Never collapses across a gap >= `gapThreshold`: the app wasn't running
    /// then, and the graph must show that discontinuity rather than interpolate through it.
    /// Archive-only — the live instance feeds rate/EMA/projection math and must stay dense.
    nonisolated static func collapsePlateaus(_ samples: [UtilizationSample], gapThreshold: TimeInterval) -> [UtilizationSample] {
        guard let first = samples.first else { return [] }
        var result: [UtilizationSample] = []
        var runStart = first
        var runLast = first
        for sample in samples.dropFirst() {
            let sameValue = sample.utilization == runLast.utilization
            let smallGap = sample.timestamp.timeIntervalSince(runLast.timestamp) < gapThreshold
            if sameValue && smallGap {
                runLast = sample
                continue
            }
            result.append(runStart)
            if runLast.timestamp != runStart.timestamp {
                result.append(runLast)
            }
            runStart = sample
            runLast = sample
        }
        result.append(runStart)
        if runLast.timestamp != runStart.timestamp {
            result.append(runLast)
        }
        return result
    }

    /// Applies `replacement` to `storage[identity]` only if `generation` still equals
    /// `capturedGeneration` — i.e. no `clearAll()`/`switchOrganization()` has run since the
    /// caller captured it. Returns whether the write was applied.
    ///
    /// Extracted out of `archiveWindow` (rather than inlined at each of its two write sites)
    /// for two reasons: it de-duplicates the identical guard that appeared at both the
    /// "nothing to archive" early-return and the main post-`await` write, and — more
    /// importantly — it gives the reentrancy guard a deterministic, non-async entry point
    /// that tests can call directly. The hazard this guards against depends on real Swift
    /// concurrency scheduling (a `clearAll()`/`switchOrganization()` call winning a race
    /// against `archiveWindow`'s internal `Task.detached` suspension), which is not reliably
    /// reproducible by timing alone — the guard's correctness is instead pinned by calling
    /// this function directly with a stale `capturedGeneration`, with no race involved.
    @discardableResult
    func applyArchiveReplacement(_ replacement: WindowInstance?, forIdentity identity: String, capturedGeneration: Int) -> Bool {
        guard generation == capturedGeneration else { return false }
        storage[identity] = replacement
        return true
    }

    /// Archives `identity`'s current stored instance (if any, and non-empty) to disk, then
    /// installs `replacement` as the new value of `storage[identity]` — `nil` to leave the
    /// identity absent from storage (the "fully missing" case), or a new/updated
    /// `WindowInstance` otherwise.
    ///
    /// Every caller that needs to write `storage[identity]` once this function's `await`
    /// resumes MUST route that write through `replacement` rather than writing it separately
    /// after calling this function: this function captures `generation` before its internal
    /// `Task.detached` suspension and, immediately upon resuming (no further `await` in
    /// between, so nothing else can interleave), only applies `replacement` via
    /// `applyArchiveReplacement` if `generation` is still what it captured. `clearAll()` and
    /// `switchOrganization()` both bump `generation` when they replace `storage` wholesale,
    /// so if either ran while this function's write was in flight, `replacement` is discarded
    /// instead of resurrecting stale data into a `storage` dict that was deliberately cleared
    /// or switched to a different organization. This makes the hazard impossible by
    /// construction rather than relying on "no current caller happens to write after
    /// archiveWindow's await".
    @discardableResult
    func archiveWindow(identity: String, resetsAt: Date, windowDuration: TimeInterval, replacingWith replacement: WindowInstance?) async -> Bool {
        let capturedGeneration = generation
        guard let instance = storage[identity], !instance.samples.isEmpty else {
            applyArchiveReplacement(replacement, forIdentity: identity, capturedGeneration: capturedGeneration)
            return false
        }
        let samples = UsageHistory.collapsePlateaus(instance.samples, gapThreshold: Constants.History.gapThreshold)

        let windowEnd = resetsAt
        let windowStart = instance.samples.first?.timestamp ?? resetsAt.addingTimeInterval(-windowDuration)

        let formatter = UsageHistory.archiveDateFormatter
        let startStr = formatter.string(from: windowStart)
        let endStr = formatter.string(from: windowEnd)
        let filename = "\(startStr)_\(endStr).\(Constants.History.windowInstanceFileExtension)"

        let archiveDir = archiveDirectory.appendingPathComponent(identity)
        let archiveURL = archiveDir.appendingPathComponent(filename)

        let id = instance.id
        let firstObservedAt = instance.firstObservedAt
        let events = instance.events
        // Samples are captured above, before clearing — data persists on disk even if the
        // app crashes mid-write, but in-memory samples are cleared unconditionally.
        storage[identity] = nil

        await Task.detached {
            do {
                try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
                let data = try WindowInstanceCodec.encode(
                    id: id,
                    resetsAt: resetsAt,
                    firstObservedAt: firstObservedAt,
                    events: events,
                    samples: samples
                )
                try data.write(to: archiveURL, options: .atomic)
            } catch {
                // Archive write failed — samples were encoded before clearing storage,
                // so operational data is unaffected. Historical archive may be incomplete.
            }
        }.value

        applyArchiveReplacement(replacement, forIdentity: identity, capturedGeneration: capturedGeneration)
        return true
    }

    /// A single archived file's parsed retention-relevant metadata: its URL and the window-end
    /// date encoded in its filename (see `archiveWindow`'s `<start>_<end>.ext` naming).
    private struct ArchiveFileEntry: Sendable {
        let url: URL
        let endDate: Date
    }

    /// Walks every identity subdirectory under `archiveBase` and parses each archive
    /// filename's window-end date. Shared by `pruneArchives` (which deletes) and
    /// `archivedWindowCount` (which only counts) so the two can never disagree about which
    /// files exist or how their dates are parsed.
    private nonisolated static func collectArchiveFiles(archiveBase: URL) -> [ArchiveFileEntry] {
        guard let identityDirs = try? FileManager.default.contentsOfDirectory(at: archiveBase, includingPropertiesForKeys: nil) else { return [] }
        let formatter = UsageHistory.archiveDateFormatter

        // Constants.History.windowInstanceFileExtension (e.g. ".dat") is the CURRENT archive
        // suffix — currently written in the v3 on-disk layout, but the extension itself is
        // format-version-agnostic (see that constant's doc comment) and has already outlived
        // one format bump (v2 -> v3) without changing; ".json.lzma" is the legacy (v1)
        // suffix, still present on disk for archives written before the binary-format
        // migration.
        let knownSuffixes = [".\(Constants.History.windowInstanceFileExtension)", Constants.History.legacyArchiveSuffix]
        var result: [ArchiveFileEntry] = []
        for identityDir in identityDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: identityDir, includingPropertiesForKeys: nil) else { continue }
            for file in files {
                let lastComponent = file.lastPathComponent
                guard let knownSuffix = knownSuffixes.first(where: { hasSuffixCaseInsensitive(lastComponent, $0) }) else { continue }
                let name = String(lastComponent.dropLast(knownSuffix.count))
                let parts = name.split(separator: "_", maxSplits: 1).map(String.init)
                guard parts.count == 2, let endDate = formatter.date(from: parts[1]) else { continue }
                result.append(ArchiveFileEntry(url: file, endDate: endDate))
            }
        }
        return result
    }

    /// Calendar-based retention cutoff: everything with a window-end date before this moment
    /// is eligible for deletion. Uses `Calendar` year arithmetic rather than a fixed
    /// seconds-per-year approximation so leap years never drift the boundary.
    nonisolated static func retentionCutoff(years: Int = Constants.History.retentionYears(), now: Date = Date()) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(byAdding: .year, value: -years, to: now)
    }

    /// Counts archived windows that WOULD be deleted under `retentionYears`, without deleting
    /// anything. Used by the Preferences UI to show a concrete count before confirming a
    /// retention decrease.
    func archivedWindowCount(retentionYears years: Int, now: Date = Date()) async -> Int {
        guard let cutoff = UsageHistory.retentionCutoff(years: years, now: now) else { return 0 }
        let archiveBase = archiveDirectory
        return await Task.detached {
            UsageHistory.collectArchiveFiles(archiveBase: archiveBase).filter { $0.endDate < cutoff }.count
        }.value
    }

    /// Deletes archived windows older than the configured (or explicitly passed) retention
    /// cutoff, then does the same for quarantined files sitting in `liveDirectory` or under any
    /// `archiveDirectory/<identity>/` (Defect 4/2 — see `pruneQuarantinedFiles`). Safe to call
    /// unconditionally and often: run once at
    /// launch, periodically thereafter, and after any detected window boundary (see
    /// DataCoordinator).
    func pruneArchives(retentionYears years: Int = Constants.History.retentionYears(), now: Date = Date()) async {
        // Structural exclusion with legacy migration (see `inFlightPrune`'s doc comment on
        // `UsageHistory`): wait for any migration already running over this same
        // `archiveDirectory` to finish before this prune's own file I/O starts, so a legacy
        // `.json.lzma` file migration is mid-processing can never be deleted out from under it.
        if let inFlightMigration = inFlightLegacyMigration {
            _ = await inFlightMigration.value
        }
        // Coalesce with any already-running prune rather than starting a second sweep over the
        // same directory concurrently — mirrors `migrateLegacyArchives()`'s own coalescing.
        if let existing = inFlightPrune {
            await existing.value
            return
        }
        guard let cutoff = UsageHistory.retentionCutoff(years: years, now: now) else { return }
        let archiveBase = archiveDirectory
        let task = Task<Void, Never> {
            await Task.detached {
                for entry in UsageHistory.collectArchiveFiles(archiveBase: archiveBase) where entry.endDate < cutoff {
                    try? FileManager.default.removeItem(at: entry.url)
                }
                guard let identityDirs = try? FileManager.default.contentsOfDirectory(at: archiveBase, includingPropertiesForKeys: nil) else { return }
                for identityDir in identityDirs {
                    if let remaining = try? FileManager.default.contentsOfDirectory(at: identityDir, includingPropertiesForKeys: nil),
                       remaining.isEmpty {
                        try? FileManager.default.removeItem(at: identityDir)
                    }
                }
            }.value
        }
        inFlightPrune = task
        await task.value
        inFlightPrune = nil
        await pruneQuarantinedFiles(retentionYears: years, now: now)
    }

    /// A quarantined file in `liveDirectory` OR in any `archiveDirectory/<identity>/`
    /// subdirectory (Defect 2: a quarantined ARCHIVE — e.g.
    /// `<span>.json.lzma.corrupt_<timestamp>`, written by `quarantineArchiveFile` — previously
    /// matched no `knownSuffixes` entry in `collectArchiveFiles` and so was invisible to
    /// retention, invisible to counting, and accumulated forever with no expiry), alongside the
    /// moment it was quarantined, parsed from its filename (`quarantineTimestamp` — see
    /// UsageHistory+Persistence.swift) rather than read from filesystem attributes.
    /// `quarantinedAt` is `nil` when the name doesn't encode a timestamp — either an old-shape
    /// `.corrupt`/`.corrupt-N` file written before this scheme, or otherwise unparseable —
    /// meaning the age is unknown.
    private nonisolated static func collectQuarantinedFiles(liveDir: URL, archiveBase: URL) -> [(url: URL, quarantinedAt: Date?)] {
        var result: [(url: URL, quarantinedAt: Date?)] = []
        if let files = try? FileManager.default.contentsOfDirectory(at: liveDir, includingPropertiesForKeys: nil) {
            for file in files where isQuarantineFile(file) {
                result.append((url: file, quarantinedAt: quarantineTimestamp(file)))
            }
        }
        if let identityDirs = try? FileManager.default.contentsOfDirectory(at: archiveBase, includingPropertiesForKeys: nil) {
            for identityDir in identityDirs {
                guard let files = try? FileManager.default.contentsOfDirectory(at: identityDir, includingPropertiesForKeys: nil) else { continue }
                for file in files where isQuarantineFile(file) {
                    result.append((url: file, quarantinedAt: quarantineTimestamp(file)))
                }
            }
        }
        return result
    }

    /// Deletes quarantined files that have sat in `liveDirectory` or under any
    /// `archiveDirectory/<identity>/` longer than the configured retention (Defect 4: previously
    /// the only removal path for a quarantined file was the user's "Clear History", which erases
    /// ALL history — making genuine recovery impossible in practice, since using it to get rid
    /// of old quarantine debris destroys everything else too). Quarantined data is still
    /// history, so it earns the same retention treatment ordinary archives already get rather
    /// than accumulating forever — including quarantined archives (Defect 2), which previously
    /// had no removal path at all.
    ///
    /// A file whose quarantine moment can't be parsed from its name (`quarantinedAt == nil` —
    /// an old pre-timestamp `.corrupt`/`.corrupt-N` file, consistent with how `pruneArchives`
    /// treats an unparseable archive name) is never deleted: unknown age means the retention
    /// window can never be proven to have elapsed, and deleting on a guess would be the
    /// destructive mistake this scheme exists to avoid.
    func pruneQuarantinedFiles(retentionYears years: Int = Constants.History.retentionYears(), now: Date = Date()) async {
        guard let cutoff = UsageHistory.retentionCutoff(years: years, now: now) else { return }
        let liveDir = liveDirectory
        let archiveBase = archiveDirectory
        await Task.detached {
            for entry in UsageHistory.collectQuarantinedFiles(liveDir: liveDir, archiveBase: archiveBase) {
                guard let quarantinedAt = entry.quarantinedAt, quarantinedAt < cutoff else { continue }
                try? FileManager.default.removeItem(at: entry.url)
            }
        }.value
    }

    /// Count of quarantined files currently sitting in `liveDirectory` or under any
    /// `archiveDirectory/<identity>/` — exposed so a UI batch can report their existence/count
    /// (Defect 4/2: quarantine, including quarantined archives, was previously completely
    /// invisible to the user).
    func quarantinedFileCount() async -> Int {
        let liveDir = liveDirectory
        let archiveBase = archiveDirectory
        return await Task.detached {
            UsageHistory.collectQuarantinedFiles(liveDir: liveDir, archiveBase: archiveBase).count
        }.value
    }

    /// Archives any stored live instance whose window key is absent from the current API
    /// response for long enough to be unambiguous (see
    /// `Constants.History.missingWindowArchiveMultiplier`). Must only be called with the
    /// identities from a successful, complete usage fetch — a failed or partial refresh must
    /// never advance or trigger this, so callers pass identities from `currentUsage.entries`
    /// only inside the success path.
    func archiveMissingWindows(currentIdentities: Set<String>, at now: Date = Date()) async {
        let before = missingWindowSince

        // Snapshot the keys before iterating: archiveWindow() mutates `storage` (clears the
        // archived identity), and this loop suspends at `await` mid-iteration, so iterating
        // `storage.keys` directly while mutating it underneath is unsafe.
        for identity in Array(storage.keys) where !currentIdentities.contains(identity) {
            guard let firstMissingAt = missingWindowSince[identity] else {
                missingWindowSince[identity] = now
                continue
            }
            guard let duration = WindowEntry.duration(fromStorageIdentity: identity) else { continue }
            let threshold = duration * Constants.History.missingWindowArchiveMultiplier
            guard now.timeIntervalSince(firstMissingAt) >= threshold else { continue }
            guard let instance = storage[identity] else { continue }
            let resetsAt = instance.resetsAt ?? now
            await archiveWindow(identity: identity, resetsAt: resetsAt, windowDuration: duration, replacingWith: nil)
            missingWindowSince[identity] = nil
        }
        for identity in currentIdentities {
            missingWindowSince[identity] = nil
        }

        // Persist the clock so a restart doesn't reset how long each key has been missing
        // (see Task 2: without this, `missingWindowSince` was in-memory only and a window
        // that vanished from the API would sit in live/ forever, since the app would need to
        // run one full window duration uninterrupted for the threshold to ever fire).
        if missingWindowSince != before {
            await saveMissingWindowSince()
        }
    }
}
