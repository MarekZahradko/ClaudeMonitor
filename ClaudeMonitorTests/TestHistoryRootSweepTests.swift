import Foundation
import Testing
@testable import ClaudeMonitor

// MARK: - Task 3: sweep must not delete a still-live run's directory

// Exercises `TestHistoryRoot.sweepPreviousRuns` directly against a fabricated container
// directory (never the real `NSTemporaryDirectory()/ClaudeMonitorTests` container that
// `TestHistoryRoot.current` manages) so these tests can't interfere with, or be
// interfered with by, the real once-per-process sweep. No cleanup() teardown here by
// design — see CLAUDE.md's requirement that post-mortem data survive a run.
@Suite struct TestHistoryRootSweepTests {

    private func makeContainer(_ name: String) throws -> URL {
        let container = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ClaudeMonitorTests-SweepTest-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return container
    }

    private func makeRunDir(in container: URL, name: String, marker: String?) throws -> URL {
        let dir = container.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let marker {
            try marker.write(to: dir.appendingPathComponent(TestHistoryRoot.pidMarkerName), atomically: true, encoding: .utf8)
        }
        return dir
    }

    /// Builds the real `"<pid> <sec> <usec>"` marker content for `pid`, using its actual
    /// kernel-reported start time — the same format `TestHistoryRoot` itself writes.
    private func realMarker(forPID pid: pid_t) throws -> String {
        let start = try #require(TestHistoryRoot.processStartTime(pid: pid))
        return "\(pid) \(start.tv_sec) \(start.tv_usec)"
    }

    @Test func sweepSkipsDirectoryWhoseMarkerMatchesLiveProcessIdentity() throws {
        let container = try makeContainer("alive")
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let marker = try realMarker(forPID: ownPID)
        let aliveDir = try makeRunDir(in: container, name: "alive-run", marker: marker)

        TestHistoryRoot.sweepPreviousRuns(container: container)

        #expect(FileManager.default.fileExists(atPath: aliveDir.path),
                "A directory whose marker PID+start-time matches this (alive) process must not be swept.")
    }

    @Test func sweepRemovesDirectoryWithDeadPIDMarker() throws {
        let container = try makeContainer("dead")
        // PID_MAX on macOS is 99998; this is never a live process, so any start time works.
        let deadDir = try makeRunDir(in: container, name: "dead-run", marker: "999999 0 0")

        TestHistoryRoot.sweepPreviousRuns(container: container)

        #expect(!FileManager.default.fileExists(atPath: deadDir.path),
                "A directory whose marker PID is dead must be swept.")
    }

    @Test func sweepRemovesDirectoryWithNoMarker() throws {
        let container = try makeContainer("no-marker")
        let dir = try makeRunDir(in: container, name: "no-marker-run", marker: nil)

        TestHistoryRoot.sweepPreviousRuns(container: container)

        #expect(!FileManager.default.fileExists(atPath: dir.path),
                "A directory with no liveness marker must be swept.")
    }

    @Test func sweepRemovesDirectoryWithEmptyOrWhitespaceMarker() throws {
        let container = try makeContainer("empty-marker")
        let emptyDir = try makeRunDir(in: container, name: "empty-run", marker: "")
        let whitespaceDir = try makeRunDir(in: container, name: "whitespace-run", marker: "   \n  ")

        TestHistoryRoot.sweepPreviousRuns(container: container)

        #expect(!FileManager.default.fileExists(atPath: emptyDir.path),
                "A directory with an empty marker must be swept.")
        #expect(!FileManager.default.fileExists(atPath: whitespaceDir.path),
                "A directory with a whitespace-only marker must be swept.")
    }

    @Test func sweepRemovesDirectoryWithUnparsableMarker() throws {
        let container = try makeContainer("garbage-marker")
        let dir = try makeRunDir(in: container, name: "garbage-run", marker: "not-a-pid")

        TestHistoryRoot.sweepPreviousRuns(container: container)

        #expect(!FileManager.default.fileExists(atPath: dir.path),
                "A directory with an unparsable marker must be swept.")
    }

    /// Guards against the exact production bug: a marker whose PID is genuinely alive
    /// (the OS reused it) but whose recorded start time no longer matches that live
    /// process's actual start time must still be treated as dead and swept.
    @Test func sweepRemovesDirectoryWhosePIDIsLiveButIdentityDoesNotMatch() throws {
        let container = try makeContainer("pid-reuse")
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // Live PID, but a start time that cannot be this process's real one.
        let mismatchedDir = try makeRunDir(in: container, name: "reused-pid-run", marker: "\(ownPID) 1 0")

        TestHistoryRoot.sweepPreviousRuns(container: container)

        #expect(!FileManager.default.fileExists(atPath: mismatchedDir.path),
                "A directory whose PID is alive but whose recorded start time doesn't match must be swept (PID reuse).")
    }

    @Test func sweepFullyRemovesNonEmptyDirectoryTreeWithNestedSubdirsAndFiles() throws {
        let container = try makeContainer("nested")
        let dir = try makeRunDir(in: container, name: "nested-run", marker: "999999 0 0")

        // Mirror the real 57-entry-tree shape: several nested subdirectories, each with files.
        let fm = FileManager.default
        for i in 0..<3 {
            let sub = dir.appendingPathComponent("subdir-\(i)", isDirectory: true)
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            for j in 0..<3 {
                try "contents".write(to: sub.appendingPathComponent("file-\(j).txt"), atomically: true, encoding: .utf8)
            }
        }

        TestHistoryRoot.sweepPreviousRuns(container: container)

        #expect(!fm.fileExists(atPath: dir.path),
                "A non-empty directory tree with nested subdirectories and files must be fully removed.")
    }

    /// Reproduces the exact real-world wedge: a subdirectory (mirroring `UsageHistory`'s
    /// "live" directory) that was made read-only — as a test exercising a write-failure
    /// path would do — and left that way. The sweep must still fully remove the tree by
    /// restoring write permission and retrying, not leave it to wedge every future sweep.
    @Test func sweepFullyRemovesTreeContainingReadOnlySubdirectory() throws {
        let container = try makeContainer("readonly-subdir")
        let dir = try makeRunDir(in: container, name: "stale-run", marker: "999999 0 0")

        let readOnlySub = dir.appendingPathComponent("live", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlySub, withIntermediateDirectories: true)
        try "stale-data".write(to: readOnlySub.appendingPathComponent("18000.json"), atomically: true, encoding: .utf8)
        // dr-x------: readable/traversable by the owner, but not writable — this is what
        // makes deleting the files inside it (and thus the whole tree) fail without the
        // sweep's permission-restoring retry.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnlySub.path)

        TestHistoryRoot.sweepPreviousRuns(container: container)

        #expect(!FileManager.default.fileExists(atPath: dir.path),
                "A stale directory containing a read-only subdirectory with files must still be fully swept.")
    }

    @Test func isOwnerAliveTrueForOwnIdentityFalseForDeadOrMissingOrGarbageOrReusedPID() throws {
        let container = try makeContainer("isOwnerAlive")
        let ownPID = ProcessInfo.processInfo.processIdentifier

        let alive = try makeRunDir(in: container, name: "alive", marker: try realMarker(forPID: ownPID))
        let dead = try makeRunDir(in: container, name: "dead", marker: "999999 0 0")
        let missing = try makeRunDir(in: container, name: "missing", marker: nil)
        let garbage = try makeRunDir(in: container, name: "garbage", marker: "nope")
        let reused = try makeRunDir(in: container, name: "reused", marker: "\(ownPID) 1 0")

        #expect(TestHistoryRoot.isOwnerAlive(alive))
        #expect(!TestHistoryRoot.isOwnerAlive(dead))
        #expect(!TestHistoryRoot.isOwnerAlive(missing))
        #expect(!TestHistoryRoot.isOwnerAlive(garbage))
        #expect(!TestHistoryRoot.isOwnerAlive(reused))
    }
}
