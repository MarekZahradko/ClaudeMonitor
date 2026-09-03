import Foundation

/// Outcome of one run of `UsageHistory.migrateLegacyArchives()` for a single organization.
///
/// **Deliberately not surfaced in the UI, and this is a product decision — do not "fix" it.**
/// A migration is an internal storage detail the user has no way to act on or reason about, so
/// nothing about it is ever shown. `HistoryHealth` used to carry this result for a menu line that
/// has been removed, and that plumbing was deleted with it; only the seven counters below remain,
/// as the return value this type exists to be.
///
/// The known consequence, accepted with eyes open: `conflictCount` and `quarantineFailedCount`
/// describe situations their own doc comments call out as needing a human — and neither renames a
/// file, so neither is picked up by `quarantinedFileCount()` either. They are therefore visible
/// only to whoever reads this return value in a test or a debugger. That is the intended state.
/// `corruptTargetQuarantinedCount` does still reach the menu, since it genuinely quarantines a
/// file, but only as part of the undifferentiated quarantine count.
///
/// Every counter is directly asserted by `UsageHistoryLegacyArchiveMigrationTests`, which is what
/// keeps them honest in the absence of a UI consumer.
struct LegacyArchiveMigrationResult: Sendable, Equatable {
    static let none = LegacyArchiveMigrationResult()

    /// Legacy (`.json.lzma`) archives successfully re-encoded to the current format and
    /// removed this run.
    let migratedCount: Int
    /// Legacy ARCHIVES (never a target) quarantined this run and never deleted — either they
    /// failed to decode, failed round-trip verification after a successful decode, or their
    /// target filename already had a current-format file sitting at it that was independently
    /// verified to hold this exact legacy data (safe to discard the now-redundant original).
    /// This deliberately does NOT include a quarantined TARGET — see
    /// `corruptTargetQuarantinedCount` below, which is its own, distinctly-named and
    /// distinctly-surfaced count, precisely because a corrupt target quarantined during
    /// migration is a materially different (and more alarming) event than an ordinary
    /// undecodable legacy file: it means a PREVIOUSLY on-disk file for this window was corrupt.
    let quarantinedCount: Int
    /// Legacy archives left entirely untouched because their `<start>_<end>` filename span
    /// could not be parsed — retention depends on that span, so a file whose span is unknown
    /// must never be renamed, quarantined, or removed.
    let skippedUnparseableCount: Int
    /// Legacy archives that decoded and verified successfully but whose current-format write
    /// failed (full disk, permissions, ...). The legacy original is left completely untouched
    /// — nothing is lost — and this same file is retried from scratch on a future run.
    let failedWriteCount: Int
    /// Defect 1: a target existed, decoded successfully, and held a non-empty sample sequence
    /// — but its samples do NOT match the legacy original's own decoded samples. This is a
    /// genuine, unresolvable conflict, never auto-resolved: BOTH files are left completely
    /// untouched. Quarantining the legacy original could destroy data the target doesn't
    /// actually have; overwriting the target could destroy data an out-of-band recovery
    /// process already placed there. Either guess risks destroying real history, so neither is
    /// taken — this is surfaced instead so a human can inspect both files. Re-evaluated (not
    /// silently skipped) on every future run until resolved.
    let conflictCount: Int
    /// Defect 1: a pre-existing TARGET (never a legacy archive) that was quarantined this run
    /// because its mere existence proved nothing — it failed to decode, or decoded to zero
    /// samples (most likely a truncated write from an older build). This is exactly the
    /// dangerous event the developer must be told about distinctly from an ordinary quarantined
    /// legacy file: it means a file that was ALREADY supposedly-migrated data was corrupt on
    /// disk. The legacy original is NOT counted here — it is migrated normally in the same pass
    /// (see `migratedCount`) once the corrupt target is out of the way.
    let corruptTargetQuarantinedCount: Int
    /// Defect 1: an attempt to quarantine a file (either an ordinary legacy original, or a
    /// corrupt pre-existing target) failed at the filesystem level — a transient I/O error, a
    /// permission race, or the file vanishing between the existence check and the move. When
    /// this happens the affected file is left completely untouched (nothing renamed, removed,
    /// or overwritten) and is retried from scratch on a future run — counted here, distinctly
    /// from every other outcome, precisely so a failed quarantine attempt is never silently
    /// treated as a successful one nor allowed to fall through into any subsequent step that
    /// would write over, remove, or rename anything.
    let quarantineFailedCount: Int

    init(migratedCount: Int = 0, quarantinedCount: Int = 0, skippedUnparseableCount: Int = 0, failedWriteCount: Int = 0, conflictCount: Int = 0, corruptTargetQuarantinedCount: Int = 0, quarantineFailedCount: Int = 0) {
        self.migratedCount = migratedCount
        self.quarantinedCount = quarantinedCount
        self.skippedUnparseableCount = skippedUnparseableCount
        self.failedWriteCount = failedWriteCount
        self.conflictCount = conflictCount
        self.corruptTargetQuarantinedCount = corruptTargetQuarantinedCount
        self.quarantineFailedCount = quarantineFailedCount
    }
}

extension UsageHistory {
    /// One legacy file discovered under `archiveDirectory`, with its identity subdirectory
    /// name and the current-format path it would migrate to (`nil` if its `<start>_<end>`
    /// span could not be parsed).
    private struct LegacyFile: Sendable {
        let url: URL
        let targetURL: URL?
    }

    /// Cheap existence check — a single shallow directory listing per identity subdirectory,
    /// inspecting only filenames (never opening a file's contents). This is the gate that
    /// makes `migrateLegacyArchives` a true no-op (nothing read or written) when there is
    /// nothing to migrate.
    private nonisolated static func hasLegacyArchives(archiveBase: URL) -> Bool {
        guard let identityDirs = try? FileManager.default.contentsOfDirectory(at: archiveBase, includingPropertiesForKeys: nil) else { return false }
        for identityDir in identityDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: identityDir, includingPropertiesForKeys: nil) else { continue }
            if files.contains(where: { hasSuffixCaseInsensitive($0.lastPathComponent, Constants.History.legacyArchiveSuffix) }) { return true }
        }
        return false
    }

    /// Enumerates every legacy archive file under `archiveBase`. Parseability of the
    /// `<start>_<end>` span uses exactly the same test `collectArchiveFiles` uses for
    /// retention (`parts.count == 2 && end date parses`) — the start component is carried
    /// through verbatim, unvalidated, matching what retention itself relies on.
    private nonisolated static func collectLegacyFiles(archiveBase: URL) -> [LegacyFile] {
        guard let identityDirs = try? FileManager.default.contentsOfDirectory(at: archiveBase, includingPropertiesForKeys: nil) else { return [] }
        let formatter = UsageHistory.archiveDateFormatter
        var result: [LegacyFile] = []
        for identityDir in identityDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: identityDir, includingPropertiesForKeys: nil) else { continue }
            for file in files where hasSuffixCaseInsensitive(file.lastPathComponent, Constants.History.legacyArchiveSuffix) {
                let stem = String(file.lastPathComponent.dropLast(Constants.History.legacyArchiveSuffix.count))
                let parts = stem.split(separator: "_", maxSplits: 1).map(String.init)
                let target: URL?
                if parts.count == 2, formatter.date(from: parts[1]) != nil {
                    target = identityDir.appendingPathComponent("\(stem).\(Constants.History.windowInstanceFileExtension)")
                } else {
                    target = nil
                }
                result.append(LegacyFile(url: file, targetURL: target))
            }
        }
        return result
    }

    /// Outcome of one `quarantineArchiveFile` attempt. Deliberately not `URL?` (Defect 1): every
    /// call site must exhaustively `switch` over this, so a failed quarantine attempt cannot be
    /// mistaken for, or silently treated the same as, a successful one — the compiler refuses to
    /// compile a call site that only checks the success case and falls through on failure.
    private enum QuarantineAttempt: Sendable {
        case quarantined(URL)
        case failed
    }

    /// Renames `file` in place with the same `.corrupt_<timestamp>` naming scheme
    /// `UsageHistory`'s live-directory `quarantine` helper uses (see
    /// `UsageHistory+Persistence.swift`) — recognized by the same `isQuarantineFile`/
    /// `quarantineTimestamp` helpers, so a quarantined legacy archive gets the same
    /// retention-aging treatment a quarantined live file already does.
    private nonisolated static func quarantineArchiveFile(_ file: URL) -> QuarantineAttempt {
        let fm = FileManager.default
        let timestamp = archiveDateFormatter.string(from: Date())
        var candidate = file.appendingPathExtension("\(Constants.History.quarantinePrefix)\(timestamp)")
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = file.appendingPathExtension("\(Constants.History.quarantinePrefix)\(timestamp)-\(suffix)")
            suffix += 1
        }
        do {
            try fm.moveItem(at: file, to: candidate)
            return .quarantined(candidate)
        } catch {
            return .failed
        }
    }

    /// Attempts to quarantine an ordinary legacy original (never a target — see the
    /// corrupt-target branch in `migrateLegacyArchives` for that case, which has different
    /// fallthrough behavior on failure) and updates whichever counter matches the outcome. Every
    /// one of `migrateLegacyArchives`'s "quarantine this legacy file and move on" sites is
    /// routed through this single helper so they can never drift apart on how a failure is
    /// counted or handled (Defect 1) — in both outcomes the caller moves on to the next file,
    /// since quarantining (or failing to quarantine) a legacy original is never followed by any
    /// further action on that same file in this run.
    private nonisolated static func quarantineLegacyAndCount(
        _ url: URL, quarantinedCount: inout Int, quarantineFailedCount: inout Int
    ) {
        switch quarantineArchiveFile(url) {
        case .quarantined:
            quarantinedCount += 1
        case .failed:
            // Left entirely untouched — retried from scratch on a future run.
            quarantineFailedCount += 1
        }
    }

    /// One-time migration of legacy (v1, LZMA-compressed JSON) archives to the current v3
    /// binary format, scoped to a single organization's `archiveDirectory`. Safe to call on
    /// every launch: gated by `hasLegacyArchives` so a fully-migrated (or never-legacy) install
    /// does nothing beyond that one cheap directory scan.
    ///
    /// Migrates verbatim — samples are carried through dense, exactly as the legacy archive
    /// held them, with no plateau-collapse applied. This is deliberate: the round-trip check
    /// below asserts the decoded sample sequence is EXACTLY equal to the legacy one (same
    /// count, order, timestamps, utilizations) — i.e. plain element-wise `Array` equality.
    /// Migrating verbatim is what makes that the correct, literal reading of "exactly equal,"
    /// with no further interpretation needed; collapsing would instead require redefining
    /// equality as "the value recovered at every original timestamp survives under step
    /// interpretation" — a strictly weaker, extra-argued guarantee to stake irreplaceable,
    /// non-regenerable data on for a one-time operation that can never be re-run against the
    /// original bytes once they're gone. The runtime archive path already plateau-collapses
    /// everything it writes from now on (see `UsageHistory+Archive.swift`'s `archiveWindow`),
    /// so this migration's only job is getting old data into the current format losslessly, not
    /// also shrinking it.
    ///
    /// Per-file isolation: every legacy archive is migrated independently. A failure on one
    /// file (undecodable bytes, a round-trip mismatch, or a write failure) never affects any
    /// other file in the same run — there is no whole-run abort or backup. This is safe without
    /// a backup copy because of the ordering within each file (see below): the legacy original
    /// is never removed until strictly after its verified replacement is confirmed decodable
    /// on disk, so the original itself serves as its own backup for exactly as long as it's
    /// needed, and no separate copy is ever necessary.
    ///
    /// Per-file ordering, precisely:
    /// 1. If this file's target `.dat` already exists, its mere existence proves NOTHING about
    ///    whether it actually holds this legacy file's data (Defect 1 — a target can exist and
    ///    still be zero-length, truncated by an interrupted write from an older build, or
    ///    bit-rotted). So it is independently verified before anything is ever quarantined:
    ///      a. Decode the target and require a non-empty sample sequence. If that fails, the
    ///         target is corrupt — quarantine the CORRUPT TARGET (never the still-good legacy
    ///         original; counted in `corruptTargetQuarantinedCount`, deliberately never in
    ///         `quarantinedCount` — see both fields' doc comments) and fall through to migrate
    ///         this file exactly as steps 3-6 below describe, as if no target had ever existed
    ///         (the shared path now has a vacated filename to write to).
    ///      b. Otherwise, decode the legacy original itself and compare its samples against the
    ///         verified target's samples, element-wise:
    ///         - Equal: the target is PROVEN to already hold this exact legacy data — safe to
    ///           quarantine the now-redundant legacy original. Move on.
    ///         - Different: a genuine, unresolvable conflict. Neither file is touched — see
    ///           `LegacyArchiveMigrationResult.conflictCount`'s doc comment for why guessing
    ///           either direction would risk destroying real data. Move on, re-evaluated on
    ///           every future run.
    ///         - The legacy original itself fails to decode: quarantine it as in step 3 below
    ///           (this is an ordinary corrupt-legacy-file outcome, unrelated to the target).
    /// 2. If the filename span can't be parsed, leave the file untouched entirely (not even
    ///    quarantined — retention parses that span, so a file whose span is unknown must never
    ///    be renamed).
    /// 3. Decode the legacy bytes. On failure, quarantine and move on.
    /// 4. Re-encode the decoded result, decode that encoding, and assert the two sample
    ///    sequences are element-wise identical. On failure (a codec defect, not corrupt input,
    ///    but handled identically — conservatively — to any other decode-adjacent failure),
    ///    quarantine and move on.
    /// 5. Write the encoded bytes to the target path with `.atomic` (temp file + rename — never
    ///    a half-written archive). On failure, leave the legacy original untouched; this file is
    ///    retried from scratch on a future run.
    /// 6. Only now — after the verified replacement is confirmed written — best-effort remove
    ///    the legacy original (`try?`). If this specific removal fails, both files are left on
    ///    disk; step 1 above independently verifies the target holds this legacy's data on the
    ///    next run before quarantining the now-redundant legacy original, finishing the cleanup
    ///    rather than re-migrating anything.
    ///
    /// Crash recovery: since step 5 (write) always precedes step 6 (delete), and `.atomic`
    /// guarantees the write itself is all-or-nothing, a crash at ANY point leaves each file in
    /// one of only two states this migration can always recover from correctly — original
    /// present/target absent (this file simply hasn't been migrated yet, and is retried next
    /// launch, indistinguishable from never having started), or target present (original may or
    /// may not still be present; step 1's independent verification handles both, INCLUDING the
    /// case where "target present" did not in fact come from this migration's own verified
    /// write — e.g. a target left over from an interrupted write in an older build that
    /// predates this verification, or any other corruption). Every already-migrated file stays
    /// migrated; every not-yet-migrated file is picked up again on the next launch; a target
    /// that merely exists but was never actually proven to hold this data is never trusted on
    /// that existence alone.
    func migrateLegacyArchives() async -> LegacyArchiveMigrationResult {
        // Defect 2: coalesce with any already-running migration rather than starting a second
        // one over the same (or, if the org changed again mid-flight, a different) directory.
        // See `inFlightLegacyMigration`'s doc comment for why this check-then-set can never race.
        if let existing = inFlightLegacyMigration {
            return await existing.value
        }
        // Structural exclusion with pruning (see `inFlightPrune`'s doc comment on
        // `UsageHistory`): wait for any prune sweep already running over this same
        // `archiveDirectory` to finish before this migration's own file I/O starts, so a
        // legacy `.json.lzma` file this migration is about to read (or has decoded but not
        // yet written and verified a replacement for) can never be deleted out from under it.
        if let inFlightPruneTask = inFlightPrune {
            await inFlightPruneTask.value
        }
        let archiveBase = archiveDirectory
        let task = Task<LegacyArchiveMigrationResult, Never> {
            await Self.runLegacyArchiveMigration(archiveBase: archiveBase)
        }
        inFlightLegacyMigration = task
        let result = await task.value
        inFlightLegacyMigration = nil
        return result
    }

    private nonisolated static func runLegacyArchiveMigration(archiveBase: URL) async -> LegacyArchiveMigrationResult {
        await Task.detached {
            let fm = FileManager.default

            guard UsageHistory.hasLegacyArchives(archiveBase: archiveBase) else { return .none }

            let legacyFiles = UsageHistory.collectLegacyFiles(archiveBase: archiveBase)
            var migratedCount = 0
            var quarantinedCount = 0
            var skippedUnparseableCount = 0
            var failedWriteCount = 0
            var conflictCount = 0
            var corruptTargetQuarantinedCount = 0
            var quarantineFailedCount = 0

            for legacy in legacyFiles {
                guard let target = legacy.targetURL else {
                    skippedUnparseableCount += 1
                    continue
                }

                if fm.fileExists(atPath: target.path) {
                    // Defect 1: verify the target independently before ever quarantining the
                    // legacy original on the strength of the target merely existing.
                    let targetVerified: DecodedWindowInstance? = {
                        guard let targetData = try? Data(contentsOf: target),
                              let targetDecoded = try? WindowInstanceCodec.decode(targetData),
                              !targetDecoded.samples.isEmpty else { return nil }
                        return targetDecoded
                    }()

                    if let targetVerified {
                        // The target decodes and holds real samples — reconcile it against the
                        // legacy file's OWN decoded content before ever removing that original.
                        guard let legacyData = try? Data(contentsOf: legacy.url),
                              let legacyDecoded = try? WindowInstanceCodec.decode(legacyData) else {
                            // The legacy file itself is corrupt — unrelated to the target's
                            // validity — quarantine it exactly as step 3 would for any other
                            // undecodable legacy file.
                            UsageHistory.quarantineLegacyAndCount(legacy.url, quarantinedCount: &quarantinedCount, quarantineFailedCount: &quarantineFailedCount)
                            continue
                        }

                        if legacyDecoded.samples == targetVerified.samples {
                            // Proven duplicate: the target already holds this legacy file's
                            // exact data — safe to quarantine the now-redundant original.
                            UsageHistory.quarantineLegacyAndCount(legacy.url, quarantinedCount: &quarantinedCount, quarantineFailedCount: &quarantineFailedCount)
                        } else {
                            // Genuine conflict: the target decodes but disagrees with the
                            // legacy file's own content. Neither file is touched — see
                            // `LegacyArchiveMigrationResult.conflictCount`'s doc comment.
                            conflictCount += 1
                        }
                        continue
                    }

                    // The target's mere existence proved nothing: decode failure or zero
                    // samples means it is NOT a completed migration — most likely a truncated
                    // write from an older build. Quarantine the CORRUPT TARGET (never the
                    // still-good legacy original) and fall through to migrate this file exactly
                    // as if no target had ever existed — the shared path below now has a
                    // vacated filename to write to. Counted distinctly from `quarantinedCount`
                    // (see that field's doc comment) — this is the dangerous, must-surface
                    // event: a previously-migrated (or previously-written) target was corrupt.
                    //
                    // Defect 1: if this quarantine attempt itself fails, this file's migration
                    // MUST NOT fall through to the shared write path below — that path ends in
                    // an atomic write straight to `target`, which would silently destroy the
                    // still-unquarantined corrupt bytes with no trace and no way to recover
                    // them. Bail out of migrating this file entirely; both the legacy original
                    // and the corrupt target are left exactly as they were, to be retried
                    // (including re-attempting quarantine) on a future run.
                    switch UsageHistory.quarantineArchiveFile(target) {
                    case .quarantined:
                        corruptTargetQuarantinedCount += 1
                    case .failed:
                        quarantineFailedCount += 1
                        continue
                    }
                }

                guard let data = try? Data(contentsOf: legacy.url),
                      let decoded = try? WindowInstanceCodec.decode(data) else {
                    UsageHistory.quarantineLegacyAndCount(legacy.url, quarantinedCount: &quarantinedCount, quarantineFailedCount: &quarantineFailedCount)
                    continue
                }

                guard let encoded = try? WindowInstanceCodec.encode(
                        id: decoded.id,
                        resetsAt: decoded.resetsAt,
                        firstObservedAt: decoded.firstObservedAt,
                        events: decoded.events,
                        samples: decoded.samples
                      ),
                      let reDecoded = try? WindowInstanceCodec.decode(encoded),
                      reDecoded.samples == decoded.samples else {
                    UsageHistory.quarantineLegacyAndCount(legacy.url, quarantinedCount: &quarantinedCount, quarantineFailedCount: &quarantineFailedCount)
                    continue
                }

                do {
                    try encoded.write(to: target, options: .atomic)
                } catch {
                    // The legacy original is untouched — nothing is lost. Retry this same file
                    // from scratch on a future run.
                    failedWriteCount += 1
                    continue
                }

                // The verified replacement is safely on disk before this line ever runs, so
                // removing the legacy original now can never lose data — even if this specific
                // removal fails, or the process is killed immediately after (see step 1 above
                // for how a future run finishes that cleanup).
                try? fm.removeItem(at: legacy.url)
                migratedCount += 1
            }

            return LegacyArchiveMigrationResult(
                migratedCount: migratedCount,
                quarantinedCount: quarantinedCount,
                skippedUnparseableCount: skippedUnparseableCount,
                failedWriteCount: failedWriteCount,
                conflictCount: conflictCount,
                corruptTargetQuarantinedCount: corruptTargetQuarantinedCount,
                quarantineFailedCount: quarantineFailedCount
            )
        }.value
    }
}
