import Foundation
import Testing
@testable import ClaudeMonitor

/// Defect 3: every other legacy-event test either round-trips a `fromTimestamp: nil` value
/// through the CURRENT encoder (proving only that the encoder omits the key) or uses two
/// real-byte fixtures whose `events` are empty. This suite decodes `RealV2Fixtures
/// .legacyEventArchiveV2Base64` — the ONLY real file found with a genuine legacy event
/// (`fromTimestamp` absent because it predates that field) — so at least one test proves a
/// file written by the OLD code actually decodes, not merely that today's encoder/decoder
/// agree with each other. See `RealV2Fixtures` for how the raw bytes were captured/verified.
///
/// The file's metadata (magic "CMH2", format version 2, and the JSON metadata block) was
/// independently reconstructed by hand from the fixture's bytes: decoding the first 12 bytes
/// character-by-character confirms magic `CMH2`, version `2` (little-endian `02 00`), and a
/// metadata length field of 178 — which matches, byte-for-byte, the length of the JSON object
/// asserted below. The event fields and metadata values were read directly out of that JSON
/// block. The sample payload (145 samples, delta/zigzag-varint encoded) was separately decoded
/// and verified: the CRC over `metadata + payload` is valid, the payload is fully consumed
/// after exactly 145 samples with no trailing bytes, the first sample is (epoch 1786966819,
/// utilization 30), the last is (epoch 1786984801, utilization 0), and the maximum utilization
/// across all samples is 80. Those five facts, asserted below, pin this down as a real
/// regression corpus rather than a synthetic one: the archive spans 18:40:19 -> 23:40:01
/// (local), and contains BOTH the genuine mid-window credit (32 -> 0 around 18:50, unrelated
/// to any boundary) AND the boundary-lag artifact (80 -> 0 at 23:40, the exact shape Defect 1's
/// server-lag fix addresses) inside a single continuous window.
@Suite struct UsageHistoryRealFixtureTests {

    @Test func realLegacyEventArchiveDecodesSuccessfully() throws {
        let data = try #require(Data(base64Encoded: RealV2Fixtures.legacyEventArchiveV2Base64))
        #expect(data.count == 561, "Sanity check on the exact byte count of the extracted fixture.")

        let decoded = try WindowInstanceCodec.decode(data)

        #expect(decoded.id == UUID(uuidString: "9AB2D39D-D38B-4EF3-8FA5-8FC21BD95748"))
        #expect(decoded.resetsAt == Date(timeIntervalSince1970: 1786984799.729439))
        #expect(decoded.firstObservedAt == Date(timeIntervalSince1970: 1786966819))

        #expect(decoded.events.count == 1)
        let event = try #require(decoded.events.first)
        #expect(event.kind == .credit)
        #expect(event.from == 80)
        #expect(event.to == 0)
        #expect(event.at == Date(timeIntervalSince1970: 1786984801.9382381))
        #expect(event.fromTimestamp == nil, "This is exactly the real legacy event: written before `fromTimestamp` existed.")

        // Exact sample-payload assertions (see the type doc comment for how these were
        // independently verified): 145 samples, spanning first=(1786966819, 30%) to
        // last=(1786984801, 0%), peaking at 80% somewhere in between. This is what makes the
        // fixture a real regression corpus rather than a synthetic one: it contains BOTH the
        // genuine mid-window credit (an ordinary drop, unrelated to any boundary) AND the
        // boundary-lag artifact (the 80 -> 0 drop at the very end, captured as `event` above)
        // inside one continuous window.
        #expect(decoded.samples.count == 145)
        let timestamps = decoded.samples.map(\.timestamp)
        #expect(timestamps == timestamps.sorted(), "Samples must be in non-decreasing timestamp order.")
        #expect(decoded.samples.first?.timestamp == Date(timeIntervalSince1970: 1786966819))
        #expect(decoded.samples.first?.utilization == 30)
        #expect(decoded.samples.last?.timestamp == Date(timeIntervalSince1970: 1786984801))
        #expect(decoded.samples.last?.utilization == 0)
        #expect(decoded.samples.map(\.utilization).max() == 80)
    }

    /// Defect 1, proven against the REAL event above (not a hand-constructed stand-in): once
    /// this real legacy event is loaded into a `WindowInstance` and a later genuine boundary is
    /// detected, it must be partitioned by its `at` timestamp — never dropped, the way the
    /// pre-fix code dropped every `fromTimestamp == nil` event from both partitions.
    @Test @MainActor func realLegacyEventIsPartitionedByAtNotDroppedAtAGenuineBoundary() async throws {
        let data = try #require(Data(base64Encoded: RealV2Fixtures.legacyEventArchiveV2Base64))
        let decoded = try WindowInstanceCodec.decode(data)
        let realEvent = try #require(decoded.events.first)
        #expect(realEvent.fromTimestamp == nil)

        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        history.switchOrganization(UUID().uuidString)

        let identity = "18000"
        let stored = try #require(decoded.resetsAt)
        // The event's `at` (1786984801.9382381) is ~2.2s AFTER `stored` (1786984799.729439) —
        // it belongs on the CURRENT side of a boundary drawn at `stored`.
        #expect(realEvent.at > stored)

        history.storage[identity] = WindowInstance(
            id: decoded.id,
            storageIdentity: identity,
            resetsAt: stored,
            firstObservedAt: decoded.firstObservedAt,
            samples: [
                UtilizationSample(utilization: 80, timestamp: stored.addingTimeInterval(-60)),
                UtilizationSample(utilization: 0, timestamp: stored.addingTimeInterval(5)),
            ],
            events: [realEvent]
        )

        let duration: TimeInterval = 18000
        let newResetsAt = stored.addingTimeInterval(duration)
        let entry = makeEntry(key: "five_hour", utilization: 0, resetsAt: newResetsAt)
        let now = stored.addingTimeInterval(65)
        let didReset = await history.detectAndHandleReset(entry: entry, newResetsAt: newResetsAt, at: now)

        #expect(didReset)
        #expect(history.storage[identity]?.events == [realEvent],
                "The real event must be retained in the current partition (its `at` is after `stored`), never dropped.")

        let archiveDir = history.archiveDirectory.appendingPathComponent(identity)
        let archiveFiles = try FileManager.default.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil)
        #expect(archiveFiles.count == 1)
        let archived = try WindowInstanceCodec.decode(try Data(contentsOf: archiveFiles[0]))
        #expect(archived.events.isEmpty, "The event's `at` is after `stored`, so it must not end up archived.")
    }
}
