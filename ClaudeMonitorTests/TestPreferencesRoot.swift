import Foundation

/// Hands out isolated `UserDefaults(suiteName:)` domains for tests, and sweeps previous runs'
/// leftover plists at startup rather than relying on per-test teardown.
///
/// `UserDefaults.removePersistentDomain(forName:)` removes the domain from the in-memory
/// registry but does NOT delete the backing plist file under `~/Library/Preferences/` — tests
/// that called it expecting cleanup left files like `PreferencesWindowControllerTests.<uuid>.plist`
/// and `UsageHistoryRetentionTests.clamp.plist` behind on every run, accumulating exactly like
/// the junk history directories `TestHistoryRoot` already exists to prevent.
///
/// Every suite name this hands out is namespaced under `prefix`, so the startup sweep is
/// structurally bounded to files it itself could have created — it can never reach any other
/// domain, and in particular never the app's real preferences domain
/// (`com.dancingZdenda.ClaudeMonitor`), which does not and can never start with this prefix.
enum TestPreferencesRoot {
    static let prefix = "com.claudemonitor.tests."

    /// Runs exactly once per process (`static let` initializer semantics), before any suite
    /// name is handed out — mirrors `TestHistoryRoot.current`'s "sweep before this run creates
    /// anything of its own" ordering, so a run can never mistake itself for a prior one.
    private static let sweepOnce: Void = {
        sweepPreviousRuns()
    }()

    /// A fresh, unique suite name under `prefix` for a test to pass to `UserDefaults(suiteName:)`.
    /// `label` is included only to make the leftover-plist name recognizable during debugging;
    /// uniqueness comes from the appended UUID.
    static func makeSuiteName(_ label: String) -> String {
        _ = sweepOnce
        return "\(prefix)\(label).\(UUID().uuidString)"
    }

    /// Deletes every `~/Library/Preferences/<prefix>*.plist` left behind by a previous run.
    /// Bounded strictly to filenames starting with `prefix` — this can never touch any other
    /// domain's plist, including the app's real one.
    static func sweepPreviousRuns() {
        guard let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let prefsDir = libraryDir.appendingPathComponent("Preferences", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: prefsDir, includingPropertiesForKeys: nil) else { return }
        for file in files {
            guard file.lastPathComponent.hasPrefix(prefix) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
