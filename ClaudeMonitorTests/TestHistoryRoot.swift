import Darwin
import Foundation
import Testing

/// Provides an isolated on-disk root for `UsageHistory` tests, entirely outside
/// `~/Library/Application Support/` (see UsageHistory's test guard). Never touches
/// production data: see git history for the incident this replaced.
enum TestHistoryRoot {
    private static let containerName = "ClaudeMonitorTests"

    /// Name of the liveness-marker file written into each run's root directory,
    /// containing that run's PID *and* that PID's kernel-reported start time
    /// (`"<pid> <start.tv_sec> <start.tv_usec>"`). Lets the startup sweep tell a
    /// still-running process's directory apart from an abandoned one — see
    /// `sweepPreviousRuns`. Internal (not private) so tests can exercise the sweep
    /// against a fabricated container directory.
    static let pidMarkerName = ".owner.pid"

    /// One root directory per process run, under the system temp directory.
    /// Computed once per process: `NSTemporaryDirectory()/ClaudeMonitorTests/<runID>/`.
    static let current: URL = {
        let container = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(containerName, isDirectory: true)

        // Clean-at-start: remove any *previous* runs' directories, but never touch
        // the one we're about to create — post-mortem data from this run is kept
        // for debugging, only cleared by the next run's startup sweep.
        let runID = "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
        let root = container.appendingPathComponent(runID, isDirectory: true)

        // `current` is a `static let`: Swift guarantees its initializer runs exactly
        // once per process even under concurrent first access, so no extra locking
        // is needed to make this sweep run-once-per-process. Sweep runs BEFORE this
        // run's own directory is created, so this run can never mistake itself for
        // a prior one.
        Self.sweepPreviousRuns(container: container)

        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Self.writePIDMarker(in: root)
        return root
    }()

    /// Deletes only directories under `container` whose owning process is no longer
    /// alive. Directories with no marker, an empty/whitespace-only/unparsable marker,
    /// or a marker naming a dead (or PID-reused, see `isOwnerAlive`) process are treated
    /// as abandoned and swept. A directory whose marker matches a genuinely live process
    /// is left untouched, so a concurrent, overlapping `test.sh` invocation's live data
    /// is never destroyed out from under it.
    ///
    /// A failed removal is never swallowed silently: it's recorded as a Swift Testing
    /// issue so a directory this sweep *should* have removed but couldn't (a held-open
    /// file, etc.) is visible instead of quietly persisting forever. A removal that fails
    /// because part of the tree was made read-only (e.g. by a test deliberately exercising
    /// a write-failure path, and never restoring the mode bit) is retried once after
    /// forcing write permission back onto the whole subtree — see `restoreWritePermissions`.
    static func sweepPreviousRuns(container: URL) {
        let fm = FileManager.default
        guard let existing = try? fm.contentsOfDirectory(at: container, includingPropertiesForKeys: nil) else { return }
        for dir in existing {
            guard !isOwnerAlive(dir) else { continue }
            removeStaleDirectory(dir, fm: fm)
        }
    }

    /// Removes a stale run directory, retrying once — after forcibly restoring write
    /// permission throughout the subtree — if the first attempt fails. This is what makes
    /// the sweep robust against a directory an earlier test left in a read-only state: a
    /// dead run's directory must never be able to permanently wedge every future sweep.
    /// Only records an Issue if the retry *also* fails, so a real, unfixable problem still
    /// surfaces instead of being silently swallowed a second time.
    private static func removeStaleDirectory(_ dir: URL, fm: FileManager) {
        do {
            try fm.removeItem(at: dir)
            return
        } catch {
            // Fall through to the permission-restoring retry below.
        }

        restoreWritePermissions(in: dir, fm: fm)
        do {
            try fm.removeItem(at: dir)
        } catch {
            Issue.record("TestHistoryRoot sweep failed to remove stale directory at \(dir.path) even after restoring write permissions: \(error)")
        }
    }

    /// Recursively adds the owner-write bit to `dir` and everything under it. `dir` is
    /// always a child of the `NSTemporaryDirectory()/ClaudeMonitorTests` container (the sole
    /// caller, `removeStaleDirectory`, only ever passes directories it enumerated from that
    /// container), so this never reaches outside that subtree. Best-effort: any entry that
    /// still can't be made writable (e.g. it's owned by another user) is left as-is and
    /// surfaces via the removal failure this is meant to unblock, not here.
    private static func restoreWritePermissions(in dir: URL, fm: FileManager) {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [], errorHandler: { _, _ in true }) else {
            return
        }
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            try? fm.setAttributes([.posixPermissions: isDirectory ? 0o755 : 0o644], ofItemAtPath: url.path)
        }
    }

    private static func writePIDMarker(in root: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        // If we can't read our own start time (should never happen), fall back to
        // writing just the PID; `isOwnerAlive` treats a malformed/incomplete marker
        // as dead, so worst case this run's directory gets swept a run early rather
        // than lingering forever — the safe failure direction.
        guard let start = processStartTime(pid: pid) else {
            try? String(pid).write(to: root.appendingPathComponent(pidMarkerName), atomically: true, encoding: .utf8)
            return
        }
        let marker = "\(pid) \(start.tv_sec) \(start.tv_usec)"
        try? marker.write(to: root.appendingPathComponent(pidMarkerName), atomically: true, encoding: .utf8)
    }

    /// A stale directory's marker records both a PID and that PID's start time.
    /// `kill(pid, 0) == 0` alone is NOT sufficient: PIDs are reused by the OS, so a
    /// dead run's PID can later be assigned to an unrelated, genuinely live process,
    /// which would make a purely PID-based check report "alive" forever and leak the
    /// stale directory permanently. Requiring the live process's start time to match
    /// the one recorded at marker-write time rules that out: a reused PID will almost
    /// certainly have started at a different instant. (Chosen over an age-based
    /// backstop because it's exact rather than a heuristic threshold that risks either
    /// sweeping a legitimately long-running concurrent run or missing a fast PID reuse.)
    static func isOwnerAlive(_ dir: URL) -> Bool {
        let markerURL = dir.appendingPathComponent(pidMarkerName)
        guard let content = try? String(contentsOf: markerURL, encoding: .utf8) else { return false }
        let parts = content.split(whereSeparator: { $0 == " " || $0.isNewline })
        guard parts.count == 3,
              let pid = pid_t(parts[0]),
              let recordedSec = Int(parts[1]),
              let recordedUsec = Int32(parts[2]) else {
            return false
        }
        guard let liveStart = processStartTime(pid: pid) else { return false }
        return Int(liveStart.tv_sec) == recordedSec && liveStart.tv_usec == recordedUsec
    }

    /// Looks up the kernel-reported start time of `pid` via `sysctl(KERN_PROC_PID)`.
    /// Returns `nil` if `pid` does not currently name a process this user can query
    /// (dead, nonexistent, or owned by another user) — the caller treats `nil` as
    /// "not alive". Internal (not private) so tests can construct correctly-matching
    /// or deliberately-mismatching markers without duplicating this sysctl call.
    static func processStartTime(pid: pid_t) -> timeval? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        return info.kp_proc.p_starttime
    }

    /// A fresh, uniquely-named subdirectory under this run's root — one per `UsageHistory` instance.
    static func makeSubdirectory() -> URL {
        let dir = current.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
