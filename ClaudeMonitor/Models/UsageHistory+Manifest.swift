import Foundation

/// Per-organization metadata that doesn't belong to any single `WindowInstance`, persisted
/// at `manifest.json` alongside `live/` and `archive/` in the org directory.
///
/// `v1` (no `missingWindowSince`) never actually shipped as a file on disk before this task —
/// `v` exists so future schema changes have a documented version to branch on. Regardless of
/// `v`, decoding tolerates the field being entirely absent (an older or hand-written manifest),
/// treating that the same as "no keys currently missing".
struct HistoryManifest: Codable, Sendable, Equatable {
    var v: Int
    var missingWindowSince: [String: Date]?
}

extension UsageHistory {
    var manifestURL: URL {
        usageDirectory.appendingPathComponent(Constants.History.manifestFilename)
    }

    nonisolated static func decodeManifest(_ data: Data) -> HistoryManifest? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HistoryManifest.self, from: data)
    }

    nonisolated static func encodeManifest(_ manifest: HistoryManifest) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(manifest)
    }

    /// Loads `missingWindowSince` from `manifest.json`, merging it into the in-memory map.
    /// Called once at startup (from `load()`), so a brief synchronous read is acceptable —
    /// consistent with `load()`'s own synchronous v2/legacy file reads.
    ///
    /// Any stored timestamp after `now` is clamped down to `now`: a future timestamp is
    /// nonsensical (this clock only ever moves forward via `Date()` at write time), and
    /// `archiveMissingWindows` measures elapsed time as `now - firstMissingAt`, so an
    /// unclamped future value could only ever make that elapsed time smaller than reality —
    /// clamping is defensive hardening against corrupt/hand-edited manifests, not a fix for
    /// an otherwise-observed bug.
    func loadMissingWindowSince(at now: Date = Date()) {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = UsageHistory.decodeManifest(data),
              let stored = manifest.missingWindowSince else { return }
        for (identity, date) in stored {
            missingWindowSince[identity] = min(date, now)
        }
    }

    /// Writes the current `missingWindowSince` map to `manifest.json`. `.atomic` (as used
    /// throughout this codebase's other on-disk writes, e.g. `archiveWindow`, `saveInstance`)
    /// writes to a temp file in the same directory and renames it into place, so a crash
    /// mid-write can never leave a truncated manifest.
    func saveMissingWindowSince() async {
        let snapshot = missingWindowSince
        let url = manifestURL
        await Task.detached {
            let manifest = HistoryManifest(v: Constants.History.manifestVersion, missingWindowSince: snapshot)
            guard let data = UsageHistory.encodeManifest(manifest) else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                // Best-effort: a failed manifest write only delays missing-window archiving
                // (never causes incorrect archiving), so it's safe to swallow here.
            }
        }.value
    }
}
