import Testing
import Foundation
@testable import ClaudeMonitor

/// Token accounting from Claude Code's session logs. The whole energy estimate is built on these
/// numbers, and the failure mode is silent: a wrong total still renders as a plausible reading.
struct EnergyTokenLogTests {

    // A real assistant line, trimmed to the fields that matter but keeping the shapes that caused
    // trouble: `iterations` mirroring the top-level counts, and `thinking_tokens` inside
    // `output_tokens_details`. Both must be ignored.
    private let assistantLine = """
    {"type":"assistant","requestId":"req_ABC","uuid":"uuid-1","timestamp":"2026-09-14T11:49:27.383Z",\
    "isSidechain":false,"message":{"id":"msg_ABC","model":"claude-opus-5","role":"assistant",\
    "usage":{"input_tokens":2,"cache_creation_input_tokens":63195,"cache_read_input_tokens":27949,\
    "output_tokens":197,"output_tokens_details":{"thinking_tokens":76},\
    "cache_creation":{"ephemeral_1h_input_tokens":63195,"ephemeral_5m_input_tokens":0},\
    "service_tier":"standard","iterations":[{"input_tokens":2,"output_tokens":197,\
    "cache_read_input_tokens":27949,"cache_creation_input_tokens":63195,"type":"message","model":null}],\
    "speed":"standard"}}}
    """

    private func entry(from line: String) throws -> TokenLogEntry {
        guard case .entry(let entry) = TokenLogReader.parse(line: line) else {
            throw TestFailure.notAnEntry
        }
        return entry
    }

    private enum TestFailure: Error { case notAnEntry }

    // MARK: - Parsing

    @Test func parsesTheFourTokenCountsFromARealLine() throws {
        let parsed = try entry(from: assistantLine)
        #expect(parsed.usage.input == 2)
        #expect(parsed.usage.cacheCreation == 63195)
        #expect(parsed.usage.cacheRead == 27949)
        #expect(parsed.usage.output == 197)
        #expect(parsed.model == "claude-opus-5")
        #expect(parsed.dedupKey == "msg_ABC")
    }

    /// `thinking_tokens` (76) sits inside `output_tokens` (197). Adding it would report 273.
    @Test func thinkingTokensAreNotCountedOnTopOfOutput() throws {
        let parsed = try entry(from: assistantLine)
        #expect(parsed.usage.output == 197)
        #expect(parsed.usage.total == 2 + 63195 + 27949 + 197)
    }

    /// `iterations` repeats the same counts. Reading it would double every number on the line.
    @Test func iterationsAreNotAddedToTheTopLevelCounts() throws {
        let parsed = try entry(from: assistantLine)
        #expect(parsed.usage.cacheRead == 27949, "27949 doubled to 55898 would mean iterations leaked in")
    }

    @Test func timestampIsParsedWithFractionalSeconds() throws {
        let parsed = try entry(from: assistantLine)
        let expected = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-09-14T11:49:27.383Z")
        #expect(parsed.timestamp == expected)
    }

    // MARK: - Lines that are not responses

    @Test func nonAssistantLinesAreSkippedNotCountedAsBroken() {
        let userLine = #"{"type":"user","message":{"role":"user","content":"hi"}}"#
        #expect(TokenLogReader.parse(line: userLine) == .notAnAssistantResponse)
    }

    @Test func assistantLineWithoutUsageIsSkipped() {
        let line = #"{"type":"assistant","message":{"id":"msg_X","model":"claude-opus-5"}}"#
        #expect(TokenLogReader.parse(line: line) == .notAnAssistantResponse)
    }

    /// Claude Code appends while the app reads, so a half-written final line is normal traffic.
    @Test func truncatedLineIsReportedAsUnparsableRatherThanCrashing() {
        let truncated = String(assistantLine.dropLast(40))
        #expect(TokenLogReader.parse(line: truncated) == .unparsable)
    }

    @Test func accumulatorCountsUnparsableLinesWithoutDerailingTheTotals() {
        var acc = TokenAccumulator()
        acc.add(line: String(assistantLine.dropLast(40)))
        acc.add(line: assistantLine)
        #expect(acc.totals.unparsableLines == 1)
        #expect(acc.totals.requests == 1)
        #expect(acc.totals.usage.output == 197)
    }

    // MARK: - Deduplication

    /// The headline risk: raw summing overstates output tokens by 2.76× on real logs.
    @Test func sameResponseSeenTwiceIsCountedOnce() {
        var acc = TokenAccumulator()
        acc.add(line: assistantLine)
        acc.add(line: assistantLine)
        #expect(acc.totals.requests == 1)
        #expect(acc.totals.skippedDuplicates == 1)
        #expect(acc.totals.usage.output == 197, "394 would mean the duplicate was summed in")
        #expect(acc.totals.usage.cacheRead == 27949)
    }

    @Test func differentResponsesBothCount() {
        var acc = TokenAccumulator()
        acc.add(line: assistantLine)
        acc.add(line: assistantLine.replacingOccurrences(of: "msg_ABC", with: "msg_DEF"))
        #expect(acc.totals.requests == 2)
        #expect(acc.totals.skippedDuplicates == 0)
        #expect(acc.totals.usage.output == 394)
    }

    /// 23 assistant lines in the real logs carry no requestId, so the key has to fall through.
    @Test func dedupFallsBackToRequestIdThenUuidWhenMessageIdIsMissing() throws {
        let noMessageId = """
        {"type":"assistant","requestId":"req_ONLY","uuid":"uuid-9","message":{"model":"claude-opus-5",\
        "usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        #expect(try entry(from: noMessageId).dedupKey == "req_ONLY")

        let uuidOnly = """
        {"type":"assistant","uuid":"uuid-9","message":{"model":"claude-opus-5",\
        "usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        #expect(try entry(from: uuidOnly).dedupKey == "uuid-9")
    }

    // MARK: - Per-model split

    /// Energy per token differs by model size, so the totals have to stay separable by model.
    @Test func totalsAreSplitPerModel() {
        var acc = TokenAccumulator()
        acc.add(line: assistantLine)
        acc.add(line: assistantLine
            .replacingOccurrences(of: "msg_ABC", with: "msg_SON")
            .replacingOccurrences(of: "claude-opus-5", with: "claude-sonnet-5"))
        #expect(acc.totals.byModel["claude-opus-5"]?.output == 197)
        #expect(acc.totals.byModel["claude-sonnet-5"]?.output == 197)
        #expect(acc.totals.usage.output == 394)
    }

    @Test func missingModelIsLabelledRatherThanDropped() throws {
        let noModel = """
        {"type":"assistant","uuid":"u1","message":{"id":"msg_NM",\
        "usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        #expect(try entry(from: noModel).model == "unknown")
    }

    // MARK: - Arithmetic

    @Test func usageAddsFieldwise() {
        let a = TokenUsage(input: 1, cacheCreation: 2, cacheRead: 3, output: 4)
        let b = TokenUsage(input: 10, cacheCreation: 20, cacheRead: 30, output: 40)
        #expect(a + b == TokenUsage(input: 11, cacheCreation: 22, cacheRead: 33, output: 44))
        #expect((a + b).total == 110)
    }

    @Test func emptyUsageIsZero() {
        #expect(TokenUsage().total == 0)
        #expect(TokenAccumulator().totals == TokenTotals())
    }
}

/// Incremental scanning: offsets, partial lines, and dedup surviving across scans. A repeat scan
/// that silently re-reads a whole file still produces plausible-looking totals, so these check the
/// observable consequence — a re-read shows up as skipped duplicates.
struct EnergyIncrementalScanTests {

    private func line(id: String, output: Int = 100, cacheRead: Int = 1000) -> String {
        """
        {"type":"assistant","requestId":"req_\(id)","uuid":"uuid-\(id)","timestamp":"2026-09-14T11:49:27.383Z",\
        "message":{"id":"msg_\(id)","model":"claude-opus-5","usage":{"input_tokens":1,\
        "cache_creation_input_tokens":0,"cache_read_input_tokens":\(cacheRead),"output_tokens":\(output)}}}
        """
    }

    /// The repo's per-run root: swept at the start of the NEXT run, never torn down by this one, so
    /// a failing assertion leaves its files behind for post-mortem. See TestHistoryRoot.
    private func makeTempDirectory() throws -> URL {
        TestHistoryRoot.makeSubdirectory()
    }

    private func write(_ text: String, to file: URL) throws {
        try text.data(using: .utf8)!.write(to: file)
    }

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: text.data(using: .utf8)!)
    }

    // MARK: - Offsets

    @Test func secondScanReadsOnlyWhatWasAppended() throws {
        let dir = try makeTempDirectory()
        let file = dir.appendingPathComponent("session.jsonl")
        try write(line(id: "A") + "\n", to: file)

        let first = TokenLogReader.scan(directory: dir)
        #expect(first.totals.requests == 1)
        #expect(first.totals.skippedDuplicates == 0)

        try append(line(id: "B") + "\n", to: file)
        let second = TokenLogReader.scan(directory: dir, state: first)

        #expect(second.totals.requests == 2)
        // The decisive assertion: re-reading line A would have collapsed it as a duplicate.
        #expect(second.totals.skippedDuplicates == 0, "a non-zero count means the file was re-read from the start")
        #expect(second.totals.usage.output == 200)
    }

    @Test func scanWithNoNewBytesChangesNothing() throws {
        let dir = try makeTempDirectory()
        try write(line(id: "A") + "\n", to: dir.appendingPathComponent("s.jsonl"))

        let first = TokenLogReader.scan(directory: dir)
        let second = TokenLogReader.scan(directory: dir, state: first)
        #expect(second.totals == first.totals)
        #expect(second.offsets == first.offsets)
    }

    // MARK: - Partial lines

    /// Claude Code appends while the app reads, so catching a half-written final line is routine.
    /// The offset must stop before it, and the line must be counted once it is complete.
    @Test func partialFinalLineIsLeftForTheNextScanAndCountedOnce() throws {
        let dir = try makeTempDirectory()
        let file = dir.appendingPathComponent("s.jsonl")

        let whole = line(id: "B")
        let half = String(whole.prefix(whole.count / 2))
        try write(line(id: "A") + "\n" + half, to: file)

        let first = TokenLogReader.scan(directory: dir)
        #expect(first.totals.requests == 1)
        #expect(first.totals.unparsableLines == 0, "a partial tail must not be parsed at all, let alone counted as broken")

        try append(String(whole.dropFirst(whole.count / 2)) + "\n", to: file)
        let second = TokenLogReader.scan(directory: dir, state: first)

        #expect(second.totals.requests == 2)
        #expect(second.totals.skippedDuplicates == 0)
        #expect(second.totals.unparsableLines == 0)
    }

    @Test func offsetStopsAtTheLastNewlineNotTheEndOfFile() throws {
        let dir = try makeTempDirectory()
        let file = dir.appendingPathComponent("s.jsonl")
        let complete = line(id: "A") + "\n"
        try write(complete + "{\"type\":\"assistant\",\"message\":{\"usage\":{", to: file)

        let state = TokenLogReader.scan(directory: dir)
        #expect(state.offsets[TokenLogReader.offsetKey(for: file)] == UInt64(complete.utf8.count))
    }

    // MARK: - Rewritten files

    @Test func fileThatShrankIsReadFromTheStartAgain() throws {
        let dir = try makeTempDirectory()
        let file = dir.appendingPathComponent("s.jsonl")
        try write(line(id: "A") + "\n" + line(id: "B") + "\n", to: file)

        let first = TokenLogReader.scan(directory: dir)
        #expect(first.totals.requests == 2)

        // Rewritten shorter, with a response the previous scan never saw.
        try write(line(id: "C") + "\n", to: file)
        let second = TokenLogReader.scan(directory: dir, state: first)

        #expect(second.totals.requests == 3, "the stale offset pointed past the new end; it has to reset")
        #expect(second.offsets[TokenLogReader.offsetKey(for: file)] == UInt64((line(id: "C") + "\n").utf8.count))
    }

    // MARK: - Dedup across files

    /// Most duplicates sit inside one file, but some span several, so per-file dedup is not enough.
    @Test func sameResponseInTwoFilesIsCountedOnce() throws {
        let dir = try makeTempDirectory()
        try write(line(id: "A") + "\n", to: dir.appendingPathComponent("one.jsonl"))
        try write(line(id: "A") + "\n", to: dir.appendingPathComponent("two.jsonl"))

        let state = TokenLogReader.scan(directory: dir)
        #expect(state.totals.requests == 1)
        #expect(state.totals.skippedDuplicates == 1)
    }

    @Test func nestedDirectoriesAreWalkedAndNonJsonlIgnored() throws {
        let dir = try makeTempDirectory()
        let nested = dir.appendingPathComponent("project/deeper")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write(line(id: "A") + "\n", to: nested.appendingPathComponent("s.jsonl"))
        try write(line(id: "B") + "\n", to: dir.appendingPathComponent("notes.txt"))

        let state = TokenLogReader.scan(directory: dir)
        #expect(state.totals.requests == 1)
    }

    // MARK: - Persisted state

    /// The whole incremental scheme breaks if the dedup key is not stable across launches, and it
    /// breaks silently: every response is simply recounted. `Hasher` is seeded per process, hence
    /// FNV-1a with a pinned expected value.
    @Test func dedupHashIsStableAcrossProcessesNotJustWithinOne() {
        #expect(StableHash.fnv1a("msg_ABC") == 12_345_039_227_892_135_049)
        #expect(StableHash.fnv1a("") == 14_695_981_039_346_656_037)
    }

    @Test func stateSurvivesARoundTripThroughJSON() throws {
        let dir = try makeTempDirectory()
        try write(line(id: "A") + "\n", to: dir.appendingPathComponent("s.jsonl"))
        let state = TokenLogReader.scan(directory: dir)

        let restored = try JSONDecoder().decode(TokenScanState.self, from: JSONEncoder().encode(state))
        #expect(restored == state)

        // And a scan resumed from the decoded state must behave like one resumed from the original.
        let again = TokenLogReader.scan(directory: dir, state: restored)
        #expect(again.totals.requests == 1)
        #expect(again.totals.skippedDuplicates == 0)
    }

    /// Regression: the same file reached through two spellings of its directory must share one
    /// offset. `FileManager`'s enumerator returns `/private/var/...` where a hand-built URL says
    /// `/var/...`; keyed on the raw path, every scan re-read the entire archive and nothing about
    /// the totals looked wrong, because dedup quietly absorbed it.
    @Test func offsetSurvivesTheDirectoryBeingSpelledDifferently() throws {
        let dir = try makeTempDirectory()
        try write(line(id: "A") + "\n", to: dir.appendingPathComponent("s.jsonl"))

        let viaPrivate = URL(fileURLWithPath: "/private" + dir.path)
        let first = TokenLogReader.scan(directory: viaPrivate)
        #expect(first.totals.requests == 1)

        let second = TokenLogReader.scan(directory: dir, state: first)
        #expect(second.totals.skippedDuplicates == 0, "the file was re-read, so the two spellings keyed differently")
        #expect(second.totals.requests == 1)
    }

    // MARK: - Product term

    /// Σ(context × output) cannot be recovered from the summed columns, so it is accumulated during
    /// the scan. Two responses with swapped shapes have equal column sums but different products.
    @Test func contextOutputProductIsAccumulatedNotDerivable() throws {
        let dir = try makeTempDirectory()
        try write(
            line(id: "A", output: 10, cacheRead: 1000) + "\n" + line(id: "B", output: 1000, cacheRead: 10) + "\n",
            to: dir.appendingPathComponent("s.jsonl")
        )
        let state = TokenLogReader.scan(directory: dir)
        // context = cacheRead + input(1); products: 1001×10 + 11×1000 = 10 010 + 11 000
        #expect(state.totals.contextOutputProduct == 21_010)
        let flat = state.totals.usage.contextRead * (state.totals.usage.output / state.totals.requests)
        #expect(flat != state.totals.contextOutputProduct, "a flat estimate must not coincide with the true product here")
    }
}
