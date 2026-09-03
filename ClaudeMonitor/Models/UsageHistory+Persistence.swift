import Foundation

extension UsageHistory {
    // Legacy (v1) compact encoding: bare JSON array `[[epoch,util],...]`. Still used by
    // WindowInstanceCodec's legacy decode path for reading old data, and by archives that
    // predate v2. The writer never emits this format anymore.
    nonisolated static func encodeCompact(_ samples: [UtilizationSample]) -> Data {
        let pairs = samples.map { "[\(Int($0.timestamp.timeIntervalSince1970)),\($0.utilization)]" }
        let json = "[" + pairs.joined(separator: ",") + "]"
        return Data(json.utf8)
    }

    /// Decodes the legacy (v1) compact array format. A single unparsable `[epoch,util]` pair
    /// fails the WHOLE decode (returns `nil`) rather than being silently dropped — a
    /// partially-malformed legacy file must surface as a decode failure so the caller can
    /// preserve it, never as partial data that looks like a complete, successfully-read file.
    nonisolated static func decodeCompact(_ data: Data) -> [UtilizationSample]? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return nil }
        var samples: [UtilizationSample] = []
        samples.reserveCapacity(raw.count)
        for pair in raw {
            guard pair.count == 2,
                  let epoch = pair[0] as? Double,
                  let util = (pair[1] as? NSNumber)?.intValue else { return nil }
            samples.append(UtilizationSample(utilization: util, timestamp: Date(timeIntervalSince1970: epoch)))
        }
        return samples
    }

    /// Writes `storage` to disk and updates `lastSaveSucceeded`/`persistenceFailingSince`
    /// (Defect 5) from the outcome. Previously a permanently failing write (full disk,
    /// read-only volume, revoked sandbox permission) failed completely silently, forever —
    /// this makes that state observable without changing the "never trap on an environmental
    /// I/O failure" rule below.
    func save() async {
        let snapshot = storage
        let liveDir = liveDirectory
        let allSucceeded = await Task.detached { () -> Bool in
            do {
                try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
            } catch {
                // Directory creation can fail for ordinary environmental reasons — a full
                // disk, a read-only or disconnected volume, revoked sandbox/TCC permission,
                // an inode limit — none of which are programmer errors, so this must never
                // assertionFailure/trap the process (see UsageHistory+Archive.swift's
                // archive-write failure, which follows the same rule). In-memory `storage`
                // is untouched; the next successful save() retries from scratch.
                return false
            }
            // Each identity is written and (if a legacy sibling exists) verified
            // independently: one identity's write failure must not stop the others from
            // being saved, and must never reach the legacy-deletion step below for that
            // identity — see saveInstance(). `succeeded` tracks whether EVERY identity in
            // this snapshot wrote successfully, for `recordSaveResult` below.
            var succeeded = true
            for (identity, instance) in snapshot {
                if !Self.saveInstance(identity: identity, instance: instance, liveDir: liveDir) {
                    succeeded = false
                }
            }
            // Quarantined files (`.corrupt`, `.corrupt-2`, ...) must NEVER be swept here as
            // "orphaned identity" files: stripping their `.corrupt` suffix yields something
            // like "18000.json", whose derived "identity" ("18000.json") never matches a real
            // storageIdentity ("18000") — so without this exclusion, a file quarantined
            // moments ago (or on any prior run) would be deleted on this very same pass,
            // silently destroying exactly the bytes quarantine exists to preserve. Routed
            // through the shared helper (see its doc comment) so this exclusion can never be
            // forgotten at another directory-clearing site.
            Self.clearLiveDirectoryEntries(in: liveDir, preservingQuarantine: true, keepingIdentities: Set(snapshot.keys))
            return succeeded
        }.value
        recordSaveResult(succeeded: allSucceeded)
    }

    /// Writes one identity's current-format file and, ONLY once (a) that write is read back successfully
    /// and (b) the legacy file's OWN contents — actually read and decoded from its bytes on
    /// disk, never assumed from current in-memory state — are provably represented in that
    /// read-back, deletes the sibling legacy (v1) file. Otherwise both would be present on
    /// the next load() with no defined precedence.
    ///
    /// Deletion safety condition: a legacy file is deleted only if (1) its bytes decode
    /// successfully via `WindowInstanceCodec.decode` (a partially-malformed legacy file fails
    /// decoding as a whole — see `decodeCompact` — rather than silently dropping entries),
    /// AND (2) every one of ITS decoded samples is present in the freshly-written
    /// current-format file's read-back. A legacy file that fails to decode is never deleted
    /// — it is quarantined (renamed with a `.corrupt` suffix) so it survives for recovery,
    /// doesn't keep participating in future saves/loads, and doesn't require crashing the
    /// process to be noticed: corrupt files are expected input (partial writes, bit rot), not
    /// a programmer error, so this never uses `assertionFailure` on that path.
    ///
    /// If the current-format write itself throws, control never reaches the legacy-handling
    /// step below (structurally, via Swift's `try`/`catch`), so a write failure can never lose
    /// the legacy file: real user history is never deleted on the strength of a write that
    /// didn't provably succeed.
    /// Returns whether this identity's current-format file was written successfully — used by
    /// `save()` to aggregate whole-save success/failure (Defect 5). The legacy-sibling
    /// handling below never affects this return value: a legacy file surviving undeleted is
    /// an expected, non-failure outcome (see its own doc comment), not a persistence failure.
    @discardableResult
    private nonisolated static func saveInstance(identity: String, instance: WindowInstance, liveDir: URL) -> Bool {
        let url = liveDir.appendingPathComponent("\(identity).\(Constants.History.windowInstanceFileExtension)")
        do {
            let data = try WindowInstanceCodec.encode(
                id: instance.id,
                resetsAt: instance.resetsAt,
                firstObservedAt: instance.firstObservedAt,
                events: instance.events,
                samples: instance.samples
            )
            try data.write(to: url, options: .atomic)
        } catch {
            // A write failure here is an ordinary environmental condition (full disk,
            // read-only volume, revoked permission, ...), not a programmer error — trapping
            // the process would turn a transient I/O hiccup into a crash. Nothing above
            // mutates `storage`, so no in-memory data is lost; this identity is simply not
            // persisted until a future save() succeeds. Bailing out here (before the
            // legacy-handling step below) also means a legacy sibling can never be deleted on
            // the strength of a write that didn't provably succeed.
            return false
        }

        let legacyURL = liveDir.appendingPathComponent("\(identity).json")
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return true }

        // Read AND decode the legacy file's own bytes — never substitute the in-memory
        // instance for "what the legacy file contained". `WindowInstanceCodec.decode` routes
        // non-magic-prefixed data (i.e. legacy `.json` files) through its legacy JSON/LZMA
        // path automatically.
        guard let legacyData = try? Data(contentsOf: legacyURL),
              let legacyDecoded = try? WindowInstanceCodec.decode(legacyData) else {
            quarantine(legacyURL)
            return true
        }

        if let readBack = try? Data(contentsOf: url),
           let verified = try? WindowInstanceCodec.decode(readBack),
           samplesRepresented(legacyDecoded.samples, in: verified.samples) {
            try? FileManager.default.removeItem(at: legacyURL)
        }
        // Else: keep the legacy file, unconditionally and silently. This is an expected,
        // recoverable outcome — not a programmer error — covering two distinct file-content
        // conditions: (a) the legacy file's own samples aren't (yet, or ever) fully
        // represented in the current in-memory instance (e.g. it holds older samples this
        // instance never loaded), or (b) the just-written current-format file failed to read
        // back decodably. Either way the correct, already-implemented behavior is exactly what
        // happens by doing nothing here: the legacy file survives to be reconsidered (or
        // merged) on a future save(), and no history is lost. Trapping the process on a
        // file-content condition would itself be the defect (see loadInstanceFile's and
        // saveInstance's decode-failure paths above, which follow the same rule).
        return true
    }

    /// A sample identity key at the codec's actual on-disk precision (whole-second epoch, see
    /// WindowInstanceCodec) rather than exact `Date` equality — the encode/decode round trip
    /// intentionally truncates sub-second precision, so comparing `Date`s directly would
    /// spuriously fail verification for every freshly-recorded (sub-second-precision) sample.
    private struct SampleKey: Hashable {
        let utilization: Int
        let epochSeconds: Int
    }

    private nonisolated static func sampleKey(_ sample: UtilizationSample) -> SampleKey {
        SampleKey(utilization: sample.utilization, epochSeconds: Int(sample.timestamp.timeIntervalSince1970))
    }

    /// True if every sample actually read from the legacy file is present among the samples
    /// just verified in the current-format read-back — i.e. the legacy file's own content,
    /// not the in-memory instance, is what's being proven survived the migration.
    ///
    /// Multiset (count-aware) containment, not mere set membership: if the legacy file holds
    /// a key twice but the read-back holds it only once, that is NOT full containment, and
    /// this must say so — a `Set`-based check would report both consumed as "already backed
    /// by whichever copy was seen first" and delete the legacy file having only actually
    /// verified one of the two occurrences. (In practice a duplicated legacy key is always an
    /// exact duplicate sample — same utilization AND same second — that both the recording
    /// and encoding pipeline naturally re-produce identically, so a dropped duplicate loses no
    /// information the legacy file's OWN successor entry didn't already carry. This function
    /// makes that assumption unnecessary rather than relying on it: the guarantee it returns
    /// is real multiset containment, not a claim that happens to hold for today's data.)
    private nonisolated static func samplesRepresented(_ legacySamples: [UtilizationSample], in verifiedSamples: [UtilizationSample]) -> Bool {
        guard !legacySamples.isEmpty else { return true }
        var remainingCounts: [SampleKey: Int] = [:]
        for sample in verifiedSamples {
            remainingCounts[sampleKey(sample), default: 0] += 1
        }
        for sample in legacySamples {
            let key = sampleKey(sample)
            guard let remaining = remainingCounts[key], remaining > 0 else { return false }
            remainingCounts[key] = remaining - 1
        }
        return true
    }

    /// True for any quarantined file — old-shape `.corrupt`/`.corrupt-2`/`.corrupt-3`, ... (no
    /// timestamp in the name — see `quarantineTimestamp`), or the current
    /// `.corrupt_<timestamp>`/`.corrupt_<timestamp>-2` shape written by `quarantine` below.
    /// Quarantined files must never be treated as an "orphaned identity" file with no
    /// corresponding active `storage` entry (see `save()`'s cleanup sweep): they're
    /// deliberately preserved forever, regardless of whether their original identity is still
    /// active.
    nonisolated static func isQuarantineFile(_ file: URL) -> Bool {
        let ext = file.pathExtension
        return ext == "corrupt" || ext.hasPrefix("corrupt-") || ext.hasPrefix(Constants.History.quarantinePrefix)
    }

    /// Parses the quarantine moment encoded in a quarantined file's name, or `nil` if the name
    /// doesn't encode one — either because it predates this scheme (old-shape `.corrupt`/
    /// `.corrupt-N`, quarantined before filenames carried a timestamp) or because it's
    /// otherwise unparseable. `nil` means "age unknown", and callers (`pruneQuarantinedFiles`)
    /// must never delete on an unknown age — deleting on a guess would be the destructive
    /// mistake this replaces (see the mtime-based defect this fixes).
    nonisolated static func quarantineTimestamp(_ file: URL) -> Date? {
        let ext = file.pathExtension
        guard ext.hasPrefix(Constants.History.quarantinePrefix) else { return nil }
        let remainder = ext.dropFirst(Constants.History.quarantinePrefix.count)
        guard remainder.count >= Constants.History.quarantineTimestampLength else { return nil }
        let datePart = String(remainder.prefix(Constants.History.quarantineTimestampLength))
        return archiveDateFormatter.date(from: datePart)
    }

    /// The single site every "clear files out of the live directory" operation must route
    /// through, so a new call site can never simply forget to think about quarantined files
    /// (see the incident this fixes: `clearAll()` used to sweep `liveDirectory` with no
    /// quarantine exclusion at all, silently destroying files quarantine exists to preserve).
    /// Every caller states its intent explicitly:
    ///
    /// - `preservingQuarantine: true` — automatic/background sweeps only (`save()`'s orphan
    ///   cleanup). A sweep the user never explicitly asked for must never be the thing that
    ///   destroys data quarantine exists to protect.
    /// - `preservingQuarantine: false` — `clearAll()` only. The user explicitly choosing
    ///   "Clear History" is a deliberate request to erase everything; a quarantined file
    ///   silently surviving an explicit "clear everything" would be a surprise, not a mercy.
    ///
    /// `keepingIdentities`, when non-nil, additionally protects any file whose derived
    /// identity is present in the set — used by `save()`'s sweep to keep files still backed
    /// by an active `storage` entry. `clearAll()` passes `nil`: it has already emptied
    /// `storage`, so every remaining file (besides what `preservingQuarantine` protects) is
    /// genuinely orphaned.
    nonisolated static func clearLiveDirectoryEntries(in liveDir: URL, preservingQuarantine: Bool, keepingIdentities activeIdentities: Set<String>? = nil) {
        let files = (try? FileManager.default.contentsOfDirectory(at: liveDir, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            if preservingQuarantine && isQuarantineFile(file) { continue }
            if let activeIdentities, activeIdentities.contains(file.deletingPathExtension().lastPathComponent) { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Renames a file with a `.corrupt` suffix rather than deleting it, so undecodable data
    /// survives for post-mortem recovery. The new extension (e.g. `dat.corrupt`,
    /// `json.corrupt`) never matches `load()`'s `.dat`/`.json` filters, so a quarantined file
    /// is never retried on a future launch, and `save()`'s cleanup sweep skips it entirely
    /// (see `isQuarantineFile`).
    ///
    /// Never overwrites a previously-quarantined file: if `identity.json.corrupt_<timestamp>`
    /// already exists (e.g. an earlier quarantine of a same-named file in the same instant),
    /// this disambiguates with a numeric suffix (`-2`, `-3`, ...) rather than destroying
    /// whatever bytes are already sitting there.
    ///
    /// The quarantine moment is encoded directly in the filename (`.corrupt_<timestamp>`)
    /// rather than stamped as a filesystem attribute afterwards: a `setAttributes` call can
    /// silently fail (read-only volume, unsupported attribute, permission race), in which case
    /// the file would keep whatever mtime `moveItem` gave it — typically the ORIGINAL file's
    /// mtime, which can be years old (making `pruneQuarantinedFiles` delete it almost
    /// immediately) or, on an inherited future mtime, immortal. Encoding the timestamp in the
    /// name removes that dependency entirely: the rename either succeeds (and the name is
    /// correct) or fails outright (and nothing is silently wrong).
    private nonisolated static func quarantine(_ file: URL) {
        let fm = FileManager.default
        let timestamp = archiveDateFormatter.string(from: Date())
        var candidate = file.appendingPathExtension("\(Constants.History.quarantinePrefix)\(timestamp)")
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = file.appendingPathExtension("\(Constants.History.quarantinePrefix)\(timestamp)-\(suffix)")
            suffix += 1
        }
        try? fm.moveItem(at: file, to: candidate)
    }

    // Synchronous by design — called once at startup before any UI is shown,
    // so a brief main-thread disk read is acceptable and avoids fire-and-forget races.
    func load() {
        // Independent of live/: a manifest can exist (and matter) even if live/ is empty
        // or missing, so this must run before the early-return below.
        loadMissingWindowSince()
        guard FileManager.default.fileExists(atPath: liveDirectory.path) else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: liveDirectory, includingPropertiesForKeys: nil)
            // Load current-format (`.dat`) files first, then legacy (v1) JSON only for
            // identities not already covered by one. `contentsOfDirectory` gives no ordering
            // guarantee, so without this split, a `.dat` file and its stale legacy sibling
            // surviving together (e.g. process killed between save()'s current-format write
            // and its legacy delete) could load in either order — nondeterministically
            // resurrecting the older, possibly incomplete legacy samples over the verified
            // ones.
            let currentFormatFiles = files.filter { $0.pathExtension == Constants.History.windowInstanceFileExtension }
            let legacyFiles = files.filter { $0.pathExtension == "json" }
            for file in currentFormatFiles {
                loadInstanceFile(file)
            }
            for file in legacyFiles {
                let identity = file.deletingPathExtension().lastPathComponent
                guard storage[identity] == nil else { continue }
                loadInstanceFile(file)
            }
        } catch {}
    }

    private func loadInstanceFile(_ file: URL) {
        let identity = file.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: file) else { return }
        do {
            let decoded = try WindowInstanceCodec.decode(data)
            storage[identity] = WindowInstance(
                id: decoded.id,
                storageIdentity: identity,
                resetsAt: decoded.resetsAt,
                firstObservedAt: decoded.firstObservedAt,
                samples: decoded.samples,
                events: decoded.events
            )
        } catch {
            // Corrupt or truncated file: a corrupt file is expected input (partial write,
            // bit rot), not a programmer error, so this must never assertionFailure/trap the
            // debug binary. Quarantine (rename with a `.corrupt` suffix) rather than deleting
            // or silently skipping-in-place: the bytes survive for recovery, and the app
            // still starts — nothing gets inserted into `storage` for this identity, exactly
            // as before, but the file itself is never lost nor left to be misread as "already
            // handled" on a future launch.
            Self.quarantine(file)
        }
    }

    /// Deletes the obsolete pre-per-organization `live/`/`archive/` layout (directly under
    /// `baseDirectory`, as opposed to the current `<orgId>/live`, `<orgId>/archive` layout).
    /// Called unconditionally once at every launch (see AppDelegate) — a no-op after the
    /// first run that ever finds them, since a fully-migrated install has nothing left here.
    ///
    /// Deliberately does NOT preserve quarantined (`.corrupt`) files under this old layout,
    /// unlike `clearAll()`'s and `save()`'s sweeps of the CURRENT per-org `live/` directory:
    /// no code path — not `load()`, not any recovery UI — ever reads from this pre-org
    /// location again, migrated or not, so a `.corrupt` file surviving here would sit
    /// forever, unreachable, inside a directory tree the rest of the app already considers
    /// gone. Preserving it would only make `migrationDeletesLegacyDirectoriesAndPreservesOrgSubdirs`
    /// (UsageHistoryMigrationTests.swift) false — it asserts `live/`/`archive/` are fully gone
    /// — while buying no actual recovery path for the user. This is the one directory-clearing
    /// site that intentionally does NOT route through `UsageHistory`'s quarantine-preserving
    /// sweep helper (see `save()`'s cleanup pass and `clearAll()`), because whole-subtree
    /// removal of an already-obsolete layout is a fundamentally different operation from
    /// sweeping orphaned files out of a directory the app still actively reads and writes.
    static func migrateAndDeleteLegacyData(baseDirectory: URL) {
        let base = baseDirectory
        let fm = FileManager.default
        let liveDir = base.appendingPathComponent("live")
        let archiveDir = base.appendingPathComponent("archive")
        try? fm.removeItem(at: liveDir)
        try? fm.removeItem(at: archiveDir)
    }
}
