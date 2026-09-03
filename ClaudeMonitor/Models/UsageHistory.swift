import Foundation

struct UtilizationSample: Sendable, Equatable {
    let utilization: Int
    let timestamp: Date
}

enum RateSource: Sendable, Equatable {
    case implied
    case insufficient
}

struct SampleSegment: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case inferred   // from (window_start, 0%) to first real sample
        case tracked    // real data from polling
        case gap        // no data period (sleep, app closed)
    }
    let kind: Kind
    let samples: [UtilizationSample]
}

struct WindowAnalysis: Sendable, Equatable {
    let entry: WindowEntry
    let samples: [UtilizationSample]
    /// Mid-window usage credit events (see `UsageEvent`) belonging to this window instance —
    /// the same events `UsageHistory.storage[identity]?.events` holds, carried through so the
    /// menu/graph layer never needs to reach into `usageHistory` directly.
    let events: [UsageEvent]
    let consumptionRate: Double
    let projectedAtReset: Double
    let timeToLimit: TimeInterval?
    let rateSource: RateSource
    let style: Formatting.UsageStyle
    let segments: [SampleSegment]
    let timeSinceLastChange: TimeInterval?
    let recentRate: Double?

    init(
        entry: WindowEntry,
        samples: [UtilizationSample],
        events: [UsageEvent] = [],
        consumptionRate: Double,
        projectedAtReset: Double,
        timeToLimit: TimeInterval?,
        rateSource: RateSource,
        style: Formatting.UsageStyle,
        segments: [SampleSegment],
        timeSinceLastChange: TimeInterval?,
        recentRate: Double? = nil
    ) {
        self.entry = entry
        self.samples = samples
        self.events = events
        self.consumptionRate = consumptionRate
        self.projectedAtReset = projectedAtReset
        self.timeToLimit = timeToLimit
        self.rateSource = rateSource
        self.style = style
        self.segments = segments
        self.timeSinceLastChange = timeSinceLastChange
        self.recentRate = recentRate
    }
}

/// A single credit/bonus mid-window utilization drop observed while polling.
/// Anthropic sometimes lowers utilization without moving `resets_at` — this is
/// recorded as an event, never treated as a window boundary.
struct UsageEvent: Sendable, Equatable, Codable {
    enum Kind: Sendable, Equatable, Codable { case credit }
    let at: Date
    let kind: Kind
    let from: Int
    let to: Int
    /// Timestamp of the sample this drop originated from — i.e. the previous sample's
    /// timestamp at the moment `record()` observed the drop, where both samples are known
    /// with certainty. This replaces the old approach of re-locating the origin sample by
    /// `(timestamp, utilization)` value matching plus a "preceding array element" positional
    /// assumption, which relied on an invariant `record()` never actually enforced and could
    /// silently mis-associate duplicate samples.
    ///
    /// `nil` only for events decoded from on-disk data written before this field existed.
    /// Such an event's true origin can never be safely reconstructed after the fact — the
    /// synthesized `Decodable` conformance treats the field's absence in old JSON as `nil`
    /// (the standard behavior for an `Optional` property), never as a guessed value.
    ///
    /// A legacy event with `fromTimestamp == nil` cannot be checked for boundary-straddling
    /// (there is no known origin to compare against the boundary), but it is NOT thereby
    /// unknown to which window it belongs: `at` — the moment the drop was recorded — is
    /// always known and reliable, and is what `UsageHistory.partitionEvents` uses to place it.
    /// Dropping it (as an earlier version of this code did) would silently destroy a real
    /// historical marker at every ordinary boundary a legacy event's window later crosses,
    /// which is strictly worse than assigning it by its one certain timestamp.
    let fromTimestamp: Date?
}

/// One concrete instance of a window's lifetime (e.g. "the 5h window that reset at 18:50").
/// Ownership of samples is recorded explicitly here and never re-derived from `resets_at`.
struct WindowInstance: Sendable, Equatable {
    let id: UUID
    let storageIdentity: String
    var resetsAt: Date?
    let firstObservedAt: Date
    var samples: [UtilizationSample]
    var events: [UsageEvent]
}

extension WindowEntry {
    /// Graph x-axis only — never use for data ownership. Window instance identity and
    /// sample ownership are tracked explicitly by `WindowInstance`, not derived from this.
    var windowStart: Date? {
        window.resetsAt.map { $0.addingTimeInterval(-duration) }
    }

    var storageIdentity: String {
        let seconds = Int(duration)
        guard let model = modelScope else { return "\(seconds)" }
        return "\(seconds)_\(model.lowercased())"
    }

    /// Recovers a window's duration from its `storageIdentity` (e.g. "604800" or
    /// "604800_sonnet") without needing the originating `WindowEntry` — used when a window
    /// has vanished from the API and only its stored identity remains (see
    /// `UsageHistory.archiveMissingWindows`).
    static func duration(fromStorageIdentity identity: String) -> TimeInterval? {
        let secondsPart = identity.split(separator: "_", maxSplits: 1).first.map(String.init) ?? identity
        return TimeInterval(secondsPart)
    }
}

@MainActor
final class UsageHistory {
    // Key is storageIdentity (e.g. "18000", "604800_sonnet"), not raw API key.
    // Holds the CURRENT window instance per identity — samples belong to the
    // instance they were recorded into, permanently.
    var storage: [String: WindowInstance] = [:]
    private var organizationId: String? = nil
    // Tracks, per identity, the moment it was first observed absent from a successful usage
    // fetch. Persisted to manifest.json (see UsageHistory+Manifest.swift) so the clock
    // survives an app restart — otherwise a window that vanished from the API would need
    // one full window duration of uninterrupted uptime before archiveMissingWindows'
    // threshold could ever fire.
    var missingWindowSince: [String: Date] = [:]

    /// Per-identity: the timestamp of the most recent `record()` call for that identity,
    /// whether or not it was deduplicated away (Defect 6). `record()`'s dedup skip
    /// deliberately does NOT advance `samples.last` — rewriting it would erase how long a
    /// plateau has actually held its value, which downstream rate/analysis code depends on —
    /// so `samples.last.timestamp` can lag the true most-recent same-value observation by up
    /// to roughly one poll interval. A `.credit` event's `fromTimestamp` must be that true
    /// most-recent moment: using the stale array timestamp there could make an event that is
    /// genuinely entirely on one side of a window boundary look like it straddles the
    /// boundary (see `partitionEvents`), and be wrongly dropped. This is intentionally NOT
    /// part of `WindowInstance`/persisted state — it only ever matters for an event created
    /// within samples this process itself just observed, and is naturally always in sync with
    /// whichever `WindowInstance` currently owns the identity (see `record()`'s doc comment on
    /// why no extra bookkeeping is needed across a boundary split), so it's cleared only
    /// alongside `storage` itself in `clearAll()`/`switchOrganization()`.
    private var lastObservedAt: [String: Date] = [:]

    // Bumped by `clearAll()` and `switchOrganization()` — the two operations that replace
    // `storage` wholesale. `archiveWindow()` captures this before its internal `await` and
    // refuses to write its post-await replacement into `storage` if it has changed,
    // structurally preventing a suspended archive from resurrecting stale data into a
    // storage dict that was deliberately cleared or switched to a different organization
    // while it was suspended (see `archiveWindow`'s doc comment).
    private(set) var generation = 0

    let baseDirectory: URL

    /// Persistence-failure tracking (Defect 5): whether the most recent `save()` wrote every
    /// identity to disk successfully. A permanently failing write (full disk, read-only
    /// volume, revoked sandbox permission) previously failed completely silently, forever —
    /// this is exposed so a UI batch can surface it. `true` until the first `save()` call
    /// completes (nothing has failed yet).
    private(set) var lastSaveSucceeded = true

    /// The moment `save()` most recently transitioned from succeeding to failing — `nil`
    /// while saves are succeeding. Set on the first failing `save()` after a success (or at
    /// startup), cleared the instant a `save()` fully succeeds again. Lets a UI report not
    /// just "saving is currently broken" but "...and has been since HH:MM".
    private(set) var persistenceFailingSince: Date?

    /// Defect 2: the in-flight `migrateLegacyArchives()` run, if any. `migrateLegacyArchives`
    /// does its file I/O in a plain `Task.detached`, so between the moment it's launched and the
    /// moment its `await` resumes, this `@MainActor` object is free to be called again — an
    /// ordinary org-switch sequence (A → B → A) can otherwise start a second migration for the
    /// same directory while the first one's detached I/O is still running, with no
    /// synchronization between the two. Checking and setting this property happens synchronously
    /// on the main actor with no `await` in between, so two overlapping callers can never both
    /// observe it `nil` and each launch their own task — the second caller always finds the
    /// first caller's task already stored and awaits that same task's result instead of starting
    /// a new one. This makes "at most one migration runs at a time" structural (enforced by
    /// actor isolation itself) rather than a manually-managed boolean flag.
    ///
    /// Not `private`: read and written from `migrateLegacyArchives()` in
    /// `UsageHistory+LegacyArchiveMigration.swift`, a different file — `private` in Swift is
    /// file-scoped, so it must be at least `internal` (the module-wide default) to be usable
    /// there. Still not part of any public API (this is an app target, not a library).
    var inFlightLegacyMigration: Task<LegacyArchiveMigrationResult, Never>?

    /// Mirrors `inFlightLegacyMigration` for `pruneArchives()`, so pruning and legacy migration
    /// structurally cannot overlap on the same `archiveDirectory`: `pruneArchives()` awaits any
    /// `inFlightLegacyMigration` before it starts, and `migrateLegacyArchives()` awaits any
    /// `inFlightPrune` before it starts — whichever operation's synchronous check-then-set runs
    /// first (never interrupted by the other, since actor-isolated code only yields at an
    /// `await`) is the one the other one waits on, so the two can never run their file I/O
    /// concurrently over the same directory in either order. Concretely, this prevents a
    /// periodic prune from deleting a legacy `.json.lzma` archive after migration has decoded it
    /// but before migration has written and verified its replacement (or before migration has
    /// even read it), and prevents a migration from starting while a prune sweep is mid-delete
    /// over the same files. See `migrateLegacyArchives()` and `pruneArchives()` for the two
    /// sides of this guarantee.
    ///
    /// Not `private` for the same file-scoping reason as `inFlightLegacyMigration` — read and
    /// written from `UsageHistory+Archive.swift` and `UsageHistory+LegacyArchiveMigration.swift`.
    var inFlightPrune: Task<Void, Never>?

    /// The single place production window-history data's on-disk location is constructed.
    /// Callers (DataCoordinator, AppDelegate) must use this rather than building the path themselves.
    static var productionBaseDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(Constants.History.productionSubdirectory)
    }

    init(baseDirectory: URL) {
        // Guard against test contamination of production data — see git history for the incident.
        // test.sh exports BuildInfo.underTestEnvVar before launching the test binary — the
        // only reliable "are we running under our own test runner" signal, since this
        // project's Swift Testing runner never loads the Objective-C test framework or sets
        // any of the environment variables that framework's runner would set.
        let isUnderTest = ProcessInfo.processInfo.environment[BuildInfo.underTestEnvVar] != nil
        if isUnderTest {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            if let appSupport, baseDirectory.standardizedFileURL.path.hasPrefix(appSupport.standardizedFileURL.path) {
                preconditionFailure("UsageHistory must never be constructed with a baseDirectory inside Application Support during tests — inject a temporary directory instead (see TestHistoryRoot).")
            }
        }
        self.baseDirectory = baseDirectory
    }

    var usageDirectory: URL {
        guard let orgId = organizationId else { return baseDirectory }
        return baseDirectory.appendingPathComponent(orgId)
    }

    var liveDirectory: URL {
        usageDirectory.appendingPathComponent("live")
    }

    var archiveDirectory: URL {
        usageDirectory.appendingPathComponent("archive")
    }

    func switchOrganization(_ orgId: String?) {
        guard orgId != organizationId else { return }
        organizationId = orgId
        storage = [:]
        missingWindowSince = [:]
        lastObservedAt = [:]
        generation += 1
        if orgId != nil {
            load()
        }
    }

    func samples(for entry: WindowEntry) -> [UtilizationSample] {
        // No filtering: ownership is by instance, not by a derived window boundary.
        storage[entry.storageIdentity]?.samples ?? []
    }

    /// The user's explicit "Clear History" action (Preferences). Deliberately erases
    /// EVERYTHING under `liveDirectory`, including quarantined (`.corrupt`) files: unlike
    /// `save()`'s background orphan sweep — which must never destroy a file quarantined for
    /// recovery — this is a direct, explicit request from the user to erase all history, and
    /// a `.corrupt` file silently surviving that request would defeat the very thing the user
    /// asked for. See `clearLiveDirectoryEntries`'s doc comment for the full policy: sweeps
    /// preserve quarantine, explicit user-initiated clears do not.
    func clearAll() async {
        storage = [:]
        missingWindowSince = [:]
        lastObservedAt = [:]
        generation += 1
        let liveDir = liveDirectory
        await Task.detached {
            Self.clearLiveDirectoryEntries(in: liveDir, preservingQuarantine: false)
        }.value
    }

    /// Updates `lastSaveSucceeded`/`persistenceFailingSince` from a single `save()`'s outcome
    /// (Defect 5). Internal (not `private`) so tests can drive it directly without needing to
    /// engineer a real disk failure (read-only volume, full disk) to exercise the state
    /// transitions.
    func recordSaveResult(succeeded: Bool, at now: Date = Date()) {
        lastSaveSucceeded = succeeded
        if succeeded {
            persistenceFailingSince = nil
        } else if persistenceFailingSince == nil {
            persistenceFailingSince = now
        }
    }

    /// Shared partitioning rule for `UsageEvent`s at a window boundary — used identically by
    /// both the genuine-boundary branch and the legacy-reconstruction branch of
    /// `detectAndHandleReset` (Defect 1: the two branches used to disagree, and the
    /// genuine-boundary branch dropped every legacy event with no `fromTimestamp` from BOTH
    /// partitions).
    ///
    /// - An event with a known `fromTimestamp` is checked for straddling: if its origin
    ///   (`fromTimestamp`) and its landing (`event.at`) fall on opposite sides of `boundary`,
    ///   it is treated as the misclassified reset itself, not a real credit, and is dropped —
    ///   but only when `boundaryIsProven` is `true` (see below).
    /// - An event with `fromTimestamp == nil` (written before that field existed — see
    ///   `UsageEvent`'s doc comment) cannot be checked for straddling, but its `at` is always
    ///   known, so it is partitioned by `at` alone rather than dropped.
    ///
    /// `boundaryIsProven` (Defect 2) distinguishes WHERE `boundary` came from, because
    /// discarding a straddling event is only justified when the boundary itself is certain:
    /// - `true` — the genuine-boundary branch's `boundary` is `stored`, an actually-persisted
    ///   `resets_at` the app previously observed and is now confirming has passed. A straddling
    ///   event against that boundary really is the misclassified reset, so dropping it is
    ///   correct.
    /// - `false` — the legacy-reconstruction branch's `boundary` (`windowStart`) is DERIVED
    ///   (`newResetsAt - duration`), never itself observed. If that derivation is even slightly
    ///   off, a legitimate credit whose origin and landing both truly belong to one window can
    ///   be computed as straddling and wrongly discarded. Discarding on an unproven guess is
    ///   the worse error, so on a derived boundary a straddling event is KEPT — assigned by
    ///   `at`, exactly as the legacy branch originally did before the two branches were unified.
    ///
    /// Inclusivity matches `WindowInstance.samples`' own boundary convention: `< boundary` is
    /// the OLD window (prior/archived), `>= boundary` is the NEW window (current/retained) —
    /// the boundary instant is the first instant of the new window, not the last instant of
    /// the old one.
    private nonisolated static func partitionEvents(_ events: [UsageEvent], at boundary: Date, boundaryIsProven: Bool) -> (prior: [UsageEvent], current: [UsageEvent]) {
        var prior: [UsageEvent] = []
        var current: [UsageEvent] = []
        for event in events {
            guard let fromTimestamp = event.fromTimestamp else {
                if event.at < boundary {
                    prior.append(event)
                } else {
                    current.append(event)
                }
                continue
            }
            let toTimestamp = event.at
            if fromTimestamp < boundary && toTimestamp < boundary {
                prior.append(event)
            } else if fromTimestamp >= boundary && toTimestamp >= boundary {
                current.append(event)
            } else if boundaryIsProven {
                // The drop spans a PROVEN boundary — it IS the misclassified reset itself,
                // not a real credit in either window, so neither partition keeps it.
            } else {
                // The drop spans a DERIVED boundary that could itself be slightly wrong —
                // discarding on that guess would be the worse error, so keep it, assigned by
                // its one certain timestamp (`at`).
                if event.at < boundary {
                    prior.append(event)
                } else {
                    current.append(event)
                }
            }
        }
        return (prior, current)
    }

    func record(entries: [WindowEntry], at date: Date = Date()) {
        // Collision guard: two entries sharing the same storageIdentity shouldn't happen.
        #if DEBUG
        var seenIdentities: [String: String] = [:]
        for entry in entries {
            let identity = entry.storageIdentity
            assert(seenIdentities[identity] == nil, "storageIdentity collision: \(identity) used by \(entry.key) and \(seenIdentities[identity]!)")
            seenIdentities[identity] = entry.key
        }
        #endif

        for entry in entries {
            let identity = entry.storageIdentity
            let utilization = entry.window.utilization

            guard var instance = storage[identity] else {
                // First observation for this identity: start a fresh instance,
                // adopting whatever resets_at is presented (unverified boundary).
                storage[identity] = WindowInstance(
                    id: UUID(),
                    storageIdentity: identity,
                    resetsAt: entry.window.resetsAt,
                    firstObservedAt: date,
                    samples: [UtilizationSample(utilization: utilization, timestamp: date)],
                    events: []
                )
                lastObservedAt[identity] = date
                continue
            }

            if let last = instance.samples.last,
               last.utilization == utilization,
               date.timeIntervalSince(last.timestamp) < Constants.History.deduplicationInterval {
                // Same value as the last recorded sample: this observation is deliberately
                // not appended (see `lastObservedAt`'s doc comment on why `samples` itself
                // must not be rewritten), but it IS the truest evidence yet of when this
                // value was last actually seen — advance that separate clock so a future
                // credit event's `fromTimestamp` doesn't understate it (Defect 6).
                lastObservedAt[identity] = date
                continue
            }

            if let last = instance.samples.last, utilization < last.utilization {
                // Use the true most-recent same-value observation time if one was tracked
                // (see `lastObservedAt`), falling back to the array's own last timestamp when
                // none was (e.g. this is the very first record() call following a restart).
                let origin = lastObservedAt[identity] ?? last.timestamp
                instance.events.append(UsageEvent(at: date, kind: .credit, from: last.utilization, to: utilization, fromTimestamp: origin))
            }

            instance.samples.append(UtilizationSample(utilization: utilization, timestamp: date))
            storage[identity] = instance
            lastObservedAt[identity] = date
        }
    }

    /// Boundary detection driven ONLY by `resets_at`. Never inspects utilization —
    /// a utilization drop is a credit event (see `record()`), not a reset signal.
    ///
    /// A boundary requires BOTH that `resets_at` moved forward AND that the previous
    /// reset moment has actually passed (`now >= stored - tolerance`). Neither an absolute
    /// nor a duration-relative magnitude threshold captures what a boundary means: a small
    /// forward nudge on a window that hasn't ended yet is drift, not a reset, while a large
    /// jump can still be a genuine boundary on a short window. This handles rolling/creeping
    /// `resets_at`, server jitter, and clock skew without any duration-derived threshold.
    ///
    /// Return value (Defect 2): `true` means a prior window's history was actually archived
    /// as a result of this call — NOT merely that `resets_at` advanced past tolerance. The
    /// `>=` inclusivity rule (see below) can leave the prior partition empty (every sample
    /// lands on the new side), in which case nothing is archived and this returns `false`
    /// even though a boundary, in the "resets_at moved forward" sense, did occur. Callers
    /// (e.g. `DataCoordinator`'s critical-reset trigger) care about "a window with recorded
    /// history just ended", not about `resets_at` bookkeeping, so that is what `true` means.
    @discardableResult
    func detectAndHandleReset(entry: WindowEntry, newResetsAt: Date?, at now: Date = Date()) async -> Bool {
        let identity = entry.storageIdentity
        guard var instance = storage[identity] else { return false }

        guard let newResetsAt else {
            // Unknown resets_at — keep the current instance, change nothing, never archive.
            return false
        }

        guard let stored = instance.resetsAt else {
            // No prior knowledge of this instance's boundary — either genuinely the first
            // observation (nothing to protect), or restored state (legacy v1 data, or a
            // restart that raced the very first save) that lacks a persisted resets_at.
            // An empty instance has no ownership conflict, so it's safe to adopt.
            if instance.samples.isEmpty {
                instance.resetsAt = newResetsAt
                storage[identity] = instance
                return false
            }

            // NON-EMPTY + no persisted boundary: legacy/restored data. These samples were
            // already pruned by the old (since-deleted) `windowStart` filter before they
            // ever reached disk, so they overwhelmingly belong to the CURRENT window — NOT
            // an "unknown prior window" to discard wholesale. Reconstruct ownership by
            // partitioning against `windowStart` derived from the freshly observed
            // `newResetsAt`. This derived boundary is trusted ONLY here, for legacy
            // reconstruction, because for this data it is the sole available and correct
            // signal; normal operation (below) never derives a boundary — it requires an
            // actually-persisted `stored` value.
            let windowStart = newResetsAt.addingTimeInterval(-entry.duration)
            let priorSamples = instance.samples.filter { $0.timestamp < windowStart }
            let currentSamples = instance.samples.filter { $0.timestamp >= windowStart }
            // Events are partitioned by the exact same shared rule as the genuine-boundary
            // branch below (see `partitionEvents`) — `resets_at` can be nil on a brand-new
            // window (see `record()`), so a credit event can be recorded before this instance
            // ever has a persisted boundary. Since that boundary is reconstructed here for
            // the first time, an event predating `windowStart` belongs to the archived prior
            // window, never to the retained one.
            let (priorEvents, currentEvents) = UsageHistory.partitionEvents(instance.events, at: windowStart, boundaryIsProven: false)

            // If the prior partition was empty, no archive is written at all — writing one
            // here (as the old code did, using `now` as a fabricated window end) is exactly
            // the bug this reconstruction fixes.
            let firstObservedAt = currentSamples.first?.timestamp ?? now
            let currentInstance = WindowInstance(
                id: priorSamples.isEmpty ? instance.id : UUID(),
                storageIdentity: identity,
                resetsAt: newResetsAt,
                firstObservedAt: firstObservedAt,
                samples: currentSamples,
                events: currentEvents
            )

            if !priorSamples.isEmpty {
                // Archive exactly the samples that precede the current window's start.
                // The prior window's true end is unknown (its resets_at was never
                // persisted), but `windowStart` — the moment the current window began — is
                // a far better approximation than `now`: the prior window ended when the
                // current one began, whereas `now` is an arbitrary later poll time.
                storage[identity] = WindowInstance(
                    id: instance.id,
                    storageIdentity: identity,
                    resetsAt: windowStart,
                    firstObservedAt: instance.firstObservedAt,
                    samples: priorSamples,
                    events: priorEvents
                )
                // `currentInstance` is routed through `archiveWindow`'s `replacingWith:`
                // rather than assigned to `storage` directly here — see that function's doc
                // comment for why a post-`await` write must never happen outside it.
                await archiveWindow(identity: identity, resetsAt: windowStart, windowDuration: entry.duration, replacingWith: currentInstance)
            } else {
                // No archiving, no `await` in this branch — a direct synchronous write is
                // safe here since nothing can suspend and race it.
                storage[identity] = currentInstance
            }
            return !priorSamples.isEmpty
        }

        let tolerance = Constants.History.resetBoundaryTolerance
        let delta = newResetsAt.timeIntervalSince(stored)

        if delta > tolerance {
            if now >= stored - tolerance {
                // Genuine new window: resets_at moved forward AND the old window's reset
                // moment has actually arrived. `stored` is the OLD window's precisely known
                // boundary instant. The API can lag one poll behind its own boundary — it may
                // report utilization dropping to 0 for the NEW instance before it has advanced
                // resets_at — so a sample already recorded at/after `stored` describes the new
                // instance, not the one being archived, and must never be archived under the
                // old window nor allowed to fabricate a "credit" against it.
                //
                // Inclusivity: a sample with timestamp == stored belongs to the NEW instance
                // (`>=`), matching the `windowStart` convention used by the legacy
                // reconstruction path above — the boundary instant is the first instant of the
                // new window, not the last instant of the old one.
                let priorSamples = instance.samples.filter { $0.timestamp < stored }
                let currentSamples = instance.samples.filter { $0.timestamp >= stored }

                // Events are partitioned by the exact same shared rule as the
                // legacy-reconstruction branch above (see `partitionEvents`): a `.credit`
                // event whose drop straddles `stored` is dropped entirely (it is the
                // misclassified reset itself, not a real credit in either window); one with no
                // recorded origin (`fromTimestamp == nil`, a legacy event) is partitioned by
                // `event.at` alone rather than dropped.
                let (priorEvents, currentEvents) = UsageHistory.partitionEvents(instance.events, at: stored, boundaryIsProven: true)

                let firstObservedAt = currentSamples.first?.timestamp ?? now
                let freshInstance = WindowInstance(
                    id: UUID(),
                    storageIdentity: identity,
                    resetsAt: newResetsAt,
                    firstObservedAt: firstObservedAt,
                    samples: currentSamples,
                    events: currentEvents
                )
                // Replace `storage[identity]` with the prior-only partition before archiving —
                // `archiveWindow` archives whatever is currently in `storage[identity]`, and
                // `freshInstance` is routed through its `replacingWith:` parameter rather than
                // assigned directly (see that function's doc comment on why a post-`await`
                // write must never happen outside it).
                storage[identity] = WindowInstance(
                    id: instance.id,
                    storageIdentity: identity,
                    resetsAt: stored,
                    firstObservedAt: instance.firstObservedAt,
                    samples: priorSamples,
                    events: priorEvents
                )
                // `archiveWindow` returns whether it actually archived something (it declines
                // when `storage[identity]` — which we just set to the prior-only partition —
                // has no samples). Defect 2: this branch previously returned `true`
                // unconditionally, so a boundary where the `>=` inclusivity rule happened to
                // put every sample on the new side (empty prior partition, nothing archived)
                // would still be reported to the caller as a genuine boundary. That `true`
                // flows into `DataCoordinator+Refresh`'s `genuineBoundaryKeys` and from there
                // into `Formatting.detectCriticalReset`, which can trigger a user-visible
                // critical-reset animation — that animation is about a window's recorded
                // history ending, not merely about `resets_at` having moved forward, so the
                // return value here means "a prior window's history was actually archived",
                // matching the legacy-reconstruction branch above (which already returns
                // `!priorSamples.isEmpty`, not an unconditional `true`).
                return await archiveWindow(identity: identity, resetsAt: stored, windowDuration: entry.duration, replacingWith: freshInstance)
            } else {
                // Forward move, but the old window hasn't ended yet — drift/extension, not
                // a boundary. Same instance: update the stored resets_at, keep samples.
                instance.resetsAt = newResetsAt
                storage[identity] = instance
                return false
            }
        } else if delta < -tolerance {
            // Backward move — ignore, keep stored value, never archive.
            return false
        } else {
            // Jitter within tolerance — same instance, keep the stored value unchanged.
            return false
        }
    }
}
