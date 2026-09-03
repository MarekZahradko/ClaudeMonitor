import Foundation
import Testing
@testable import ClaudeMonitor

// MARK: - Task 2: restart-across-boundary regression

@Suite struct RestartBoundaryTests {

    @Test @MainActor func restartAcrossBoundaryArchivesOldInstanceAndStartsCleanWithNoFabricatedEvents() async throws {
        let fixture = UsageHistoryTestFixture()
        let orgId = UUID().uuidString

        let now = Date()
        let resetsAt = now.addingTimeInterval(600)
        let entry = makeEntry(key: "five_hour", utilization: 95, resetsAt: resetsAt)

        // Session 1: instance ends high (95%), persisted with its boundary state.
        do {
            let history = fixture.history
            history.switchOrganization(orgId)
            history.record(entries: [entry], at: now)
            await history.detectAndHandleReset(entry: entry, newResetsAt: resetsAt, at: now)
            await history.save()
        }

        // Session 2: simulate an app restart via a fresh UsageHistory instance over the
        // same directory, then load() restores the persisted boundary state.
        let restarted = UsageHistory(baseDirectory: fixture.baseDirectory)
        restarted.switchOrganization(orgId)
        let restoredResetsAt = try #require(restarted.storage[entry.storageIdentity]?.resetsAt)
        #expect(abs(restoredResetsAt.timeIntervalSince(resetsAt)) < 0.01)
        #expect(restarted.storage[entry.storageIdentity]?.samples.count == 1)

        // First poll after restart: resets_at has moved forward, and `now` is past the old
        // resetsAt (the boundary genuinely passed while the app was closed).
        let newResetsAt = resetsAt.addingTimeInterval(18000)
        let pollNow = resetsAt.addingTimeInterval(30)
        let newEntry = makeEntry(key: "five_hour", utilization: 3, resetsAt: newResetsAt)
        let didReset = await restarted.detectAndHandleReset(entry: newEntry, newResetsAt: newResetsAt, at: pollNow)
        #expect(didReset, "The boundary that passed while the app was closed must be detected on the first poll after restart.")

        restarted.record(entries: [newEntry], at: pollNow)

        let newSamples = restarted.samples(for: newEntry)
        #expect(newSamples.count == 1, "The new instance must contain ONLY the new sample.")
        #expect(newSamples.first?.utilization == 3)
        #expect(restarted.storage[entry.storageIdentity]?.events.isEmpty == true,
                "No fabricated .credit event: the 95% → 3% drop is a window boundary, not a mid-window credit.")

        let archiveDir = restarted.archiveDirectory.appendingPathComponent(entry.storageIdentity)
        let archiveFiles = (try? FileManager.default.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil)) ?? []
        #expect(!archiveFiles.isEmpty, "The old (pre-restart) window must be archived.")

    }

    @Test @MainActor func restartMidWindowContinuesSameInstanceWithNoArchive() async throws {
        let fixture = UsageHistoryTestFixture()
        let orgId = UUID().uuidString

        let now = Date()
        let resetsAt = now.addingTimeInterval(9000)
        let entry = makeEntry(key: "five_hour", utilization: 40, resetsAt: resetsAt)

        do {
            let history = fixture.history
            history.switchOrganization(orgId)
            history.record(entries: [entry], at: now)
            await history.detectAndHandleReset(entry: entry, newResetsAt: resetsAt, at: now)
            await history.save()
        }

        let restarted = UsageHistory(baseDirectory: fixture.baseDirectory)
        restarted.switchOrganization(orgId)
        #expect(restarted.storage[entry.storageIdentity]?.samples.count == 1)

        // Restart happens mid-window: `now` has NOT reached resetsAt yet.
        let pollNow = now.addingTimeInterval(60)
        let sameEntry = makeEntry(key: "five_hour", utilization: 45, resetsAt: resetsAt)
        let didReset = await restarted.detectAndHandleReset(entry: sameEntry, newResetsAt: resetsAt, at: pollNow)
        #expect(!didReset)

        restarted.record(entries: [sameEntry], at: pollNow)
        let samples = restarted.samples(for: sameEntry)
        #expect(samples.count == 2, "Samples from before the restart must be preserved.")
        #expect(samples.map(\.utilization) == [40, 45])

        let archiveDir = restarted.archiveDirectory.appendingPathComponent(entry.storageIdentity)
        let archiveFiles = (try? FileManager.default.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil)) ?? []
        #expect(archiveFiles.isEmpty, "No archive on a mid-window restart.")

    }
}

// MARK: - Task 3: v2 binary codec

@Suite struct WindowInstanceCodecTests {

    private func sampleSet() -> [UtilizationSample] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return [
            UtilizationSample(utilization: 0, timestamp: base),
            UtilizationSample(utilization: 5, timestamp: base.addingTimeInterval(60)),
            UtilizationSample(utilization: 12, timestamp: base.addingTimeInterval(180)),
            UtilizationSample(utilization: 42, timestamp: base.addingTimeInterval(3600)),
        ]
    }

    @Test func roundTripPreservesMetadataAndSamples() throws {
        let id = UUID()
        let resetsAt = Date(timeIntervalSince1970: 1_700_050_000)
        let firstObservedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let events = [UsageEvent(at: firstObservedAt.addingTimeInterval(200), kind: .credit, from: 12, to: 5, fromTimestamp: firstObservedAt.addingTimeInterval(180))]
        let samples = sampleSet()

        let data = try WindowInstanceCodec.encode(id: id, resetsAt: resetsAt, firstObservedAt: firstObservedAt, events: events, samples: samples)
        let decoded = try WindowInstanceCodec.decode(data)

        #expect(decoded.id == id)
        #expect(decoded.resetsAt == resetsAt)
        #expect(decoded.firstObservedAt == firstObservedAt)
        #expect(decoded.events == events)
        #expect(decoded.samples == samples)
    }

    @Test func roundTripWithNilResetsAtAndNoEvents() throws {
        let id = UUID()
        let firstObservedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = sampleSet()

        let data = try WindowInstanceCodec.encode(id: id, resetsAt: nil, firstObservedAt: firstObservedAt, events: [], samples: samples)
        let decoded = try WindowInstanceCodec.decode(data)

        #expect(decoded.resetsAt == nil)
        #expect(decoded.events.isEmpty)
        #expect(decoded.samples == samples)
    }

    /// A legacy on-disk event has no `fromTimestamp` key at all (the field didn't exist when it
    /// was written). Encoding an event constructed with `fromTimestamp: nil` produces exactly
    /// that JSON shape — the synthesized `Encodable` conformance omits an `Optional` property's
    /// key entirely when its value is `nil` — so this exercises the real "key absent" case, not
    /// merely "key present as null". The file must decode successfully, with the field read
    /// back as `nil` rather than any guessed value.
    @Test func legacyEventMissingFromTimestampDecodesSuccessfullyAsNil() throws {
        let id = UUID()
        let firstObservedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let legacyEvent = UsageEvent(at: firstObservedAt.addingTimeInterval(200), kind: .credit, from: 12, to: 5, fromTimestamp: nil)
        let samples = sampleSet()

        let data = try WindowInstanceCodec.encode(id: id, resetsAt: nil, firstObservedAt: firstObservedAt, events: [legacyEvent], samples: samples)
        let decoded = try WindowInstanceCodec.decode(data)

        #expect(decoded.events.count == 1)
        #expect(decoded.events.first?.fromTimestamp == nil)
        #expect(decoded.events.first?.at == legacyEvent.at)
        #expect(decoded.events.first?.from == 12)
        #expect(decoded.events.first?.to == 5)
    }

    @Test func emptySamplesRoundTrip() throws {
        let data = try WindowInstanceCodec.encode(id: UUID(), resetsAt: nil, firstObservedAt: Date(), events: [], samples: [])
        let decoded = try WindowInstanceCodec.decode(data)
        #expect(decoded.samples.isEmpty)
    }

    /// Reads a little-endian UInt32 out of `data` at `offset`, mirroring the codec's own
    /// on-disk integer encoding, so tests can locate specific fields to corrupt without
    /// reaching into the codec's private parsing internals.
    private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(data[data.index(data.startIndex, offsetBy: offset + i)]) << (8 * i)
        }
        return value
    }

    @Test func corruptedPayloadByteIsDetectedViaCRC() throws {
        let samples = sampleSet()
        var data = try WindowInstanceCodec.encode(id: UUID(), resetsAt: nil, firstObservedAt: Date(), events: [], samples: samples)
        // Flip the last byte of the sample payload. In the v3 layout the CRC sits in the
        // trailing 4 bytes of the file, so this is the byte immediately before it — still
        // squarely inside the CRC-protected body, not the CRC field itself.
        let flipIndex = data.count - 5
        data[data.index(data.startIndex, offsetBy: flipIndex)] ^= 0xFF

        #expect {
            try WindowInstanceCodec.decode(data)
        } throws: { error in
            (error as? WindowInstanceCodecError) == .crcMismatch
        }
    }

    // MARK: - Task: v3 CRC coverage (Defect 2 — sampleCount/version must be CRC-covered)

    @Test func corruptedSampleCountIsDetectedViaCRC() throws {
        let samples = sampleSet()
        var data = try WindowInstanceCodec.encode(id: UUID(), resetsAt: nil, firstObservedAt: Date(), events: [], samples: samples)
        // The sample-count field is the 4 bytes immediately following metadata, at offset
        // magic(4) + version(2) + metaLen(4) + metaLen-bytes. Corrupting only this field
        // (e.g. shrinking it) must be caught by the CRC — in the old v2 layout this field
        // sat outside the CRC's coverage and could silently truncate real samples.
        let metaLen = Int(readUInt32LE(data, at: 6))
        let sampleCountOffset = 4 + 2 + 4 + metaLen
        data[data.index(data.startIndex, offsetBy: sampleCountOffset)] ^= 0xFF

        #expect {
            try WindowInstanceCodec.decode(data)
        } throws: { error in
            (error as? WindowInstanceCodecError) == .crcMismatch
        }
    }

    @Test func corruptedVersionFieldIsCaught() throws {
        let samples = sampleSet()
        var data = try WindowInstanceCodec.encode(id: UUID(), resetsAt: nil, firstObservedAt: Date(), events: [], samples: samples)
        // The version field is the 2 bytes immediately after the magic.
        data[data.index(data.startIndex, offsetBy: 4)] ^= 0xFF

        #expect {
            try WindowInstanceCodec.decode(data)
        } throws: { error in
            // The corrupted byte changes the version number itself, so the top-level
            // dispatch (which reads version before touching the CRC) rejects it as an
            // unrecognized version before the CRC is even checked. Either outcome proves the
            // corruption was caught, never silently accepted.
            switch error as? WindowInstanceCodecError {
            case .crcMismatch, .versionMismatch: return true
            default: return false
            }
        }
    }

    @Test func severelyTruncatedFileIsDetectedAsTruncated() throws {
        let data = try WindowInstanceCodec.encode(id: UUID(), resetsAt: Date(), firstObservedAt: Date(), events: [], samples: sampleSet())
        // Cut off right after magic+version — too short to even read the trailing CRC field,
        // so this is the one truncation length short enough that the CRC-first check (which
        // every longer truncation routes through, surfacing as .crcMismatch) can't run at all.
        let truncated = data.prefix(6)

        #expect {
            try WindowInstanceCodec.decode(Data(truncated))
        } throws: { error in
            (error as? WindowInstanceCodecError) == .truncated
        }
    }

    @Test func truncationMidPayloadIsDetectedViaCRC() throws {
        let data = try WindowInstanceCodec.encode(id: UUID(), resetsAt: nil, firstObservedAt: Date(), events: [], samples: sampleSet())
        // Cut off several bytes from the end, landing inside the sample payload (well before
        // the boundary of the trailing CRC field). The CRC is checked before any per-field
        // parsing, so this is always caught as a checksum mismatch, never decoded as
        // fewer-than-expected samples.
        let truncated = data.prefix(data.count - 6)

        #expect {
            try WindowInstanceCodec.decode(Data(truncated))
        } throws: { error in
            (error as? WindowInstanceCodecError) == .crcMismatch
        }
    }

    @Test func truncationInsideCRCFieldItselfIsDetected() throws {
        let data = try WindowInstanceCodec.encode(id: UUID(), resetsAt: nil, firstObservedAt: Date(), events: [], samples: sampleSet())
        // Cut off just the last byte — inside the trailing CRC field itself.
        let truncated = data.prefix(data.count - 1)

        #expect {
            try WindowInstanceCodec.decode(Data(truncated))
        } throws: { error in
            (error as? WindowInstanceCodecError) == .crcMismatch
        }
    }

    @Test func trailingBytesAfterSampleCountAreDetected() throws {
        // A `sampleCount` that's too SMALL relative to the actual payload bytes present
        // must be a typed error, not silently ignored — this is the flip side of Defect 2's
        // "sampleCount too large truncates real samples": here decoding succeeds for
        // `sampleCount` samples but leaves genuine payload bytes unconsumed.
        var data = try WindowInstanceCodec.encode(id: UUID(), resetsAt: nil, firstObservedAt: Date(), events: [], samples: sampleSet())
        let metaLen = Int(readUInt32LE(data, at: 6))
        let sampleCountOffset = 4 + 2 + 4 + metaLen
        // sampleSet() has 4 samples; claim only 1 was written. The CRC was computed over the
        // original (correct) sampleCount + full payload, so this alone would already fail
        // via CRC — recompute and overwrite the trailing CRC field to isolate the
        // trailing-bytes check instead.
        var newSampleCountBytes = Data()
        newSampleCountBytes.append(contentsOf: withUnsafeBytes(of: UInt32(1).littleEndian) { Array($0) })
        data.replaceSubrange(
            data.index(data.startIndex, offsetBy: sampleCountOffset)..<data.index(data.startIndex, offsetBy: sampleCountOffset + 4),
            with: newSampleCountBytes
        )
        let body = data.subdata(in: data.index(data.startIndex, offsetBy: 4)..<data.index(data.endIndex, offsetBy: -4))
        var newCRCBytes = Data()
        newCRCBytes.append(contentsOf: withUnsafeBytes(of: CRC32.checksum(body).littleEndian) { Array($0) })
        data.replaceSubrange(data.index(data.endIndex, offsetBy: -4)..<data.endIndex, with: newCRCBytes)

        #expect {
            try WindowInstanceCodec.decode(data)
        } throws: { error in
            (error as? WindowInstanceCodecError) == .trailingBytes
        }
    }

    @Test func legacyPlainJSONArrayIsReadable() throws {
        let samples = sampleSet()
        let legacyData = UsageHistory.encodeCompact(samples)
        let decoded = try WindowInstanceCodec.decode(legacyData)
        #expect(decoded.resetsAt == nil)
        #expect(decoded.events.isEmpty)
        #expect(decoded.samples == samples)
    }

    @Test func legacyLZMACompressedArchiveIsReadable() throws {
        let samples = sampleSet()
        let legacyJSON = UsageHistory.encodeCompact(samples)
        let compressed = try (legacyJSON as NSData).compressed(using: .lzma) as Data
        let decoded = try WindowInstanceCodec.decode(compressed)
        #expect(decoded.resetsAt == nil)
        #expect(decoded.samples == samples)
    }
}

// MARK: - Task: Defect 2 — the v2-compatibility read path against genuine v2 bytes

/// These fixtures are base64 of complete, real files recovered from an actual user's disk
/// (never round-tripped through this codec's own `encode()`, which only ever writes v3) —
/// this is what protects existing on-disk history the first time a v3 build reads it, so it
/// must be verified against the real byte layout, not just self-consistently round-tripped.
/// Their layout was independently confirmed before being embedded here: magic "CMH2",
/// version = 2 (UInt16 LE), metaLen (UInt32 LE), metadata JSON, sampleCount (UInt32 LE),
/// crc32 (UInt32 LE), payload — with the CRC computed over metadata + payload ONLY (excluding
/// `version` and `sampleCount`, exactly the gap v3 closed — see `decodeLayoutV2`'s doc
/// comment). Expected metadata/sample values below were derived by manually decoding these
/// exact bytes (base64 -> raw bytes -> the v2 field layout -> uvarint/zigzag sample deltas),
/// not guessed or copied from any other source.
@Suite struct RealV2FixtureTests {
    @Test func decodesRealV2LiveInstanceFile() throws {
        let data = try #require(Data(base64Encoded: RealV2Fixtures.liveV2Base64))
        let decoded = try WindowInstanceCodec.decode(data)

        #expect(decoded.id == UUID(uuidString: "9AB2D39D-D38B-4EF3-8FA5-8FC21BD95748"))
        #expect(decoded.firstObservedAt == Date(timeIntervalSince1970: 1786977778.329548))
        #expect(decoded.resetsAt == Date(timeIntervalSince1970: 1786984799.729439))
        #expect(decoded.events.isEmpty)
        #expect(decoded.samples.count == 18)
        #expect(decoded.samples.first?.utilization == 32)
        #expect(decoded.samples.first?.timestamp == Date(timeIntervalSince1970: 1786977778))
        #expect(decoded.samples.last?.utilization == 36)
        #expect(decoded.samples.last?.timestamp == Date(timeIntervalSince1970: 1786978875))
    }

    @Test func decodesRealV2ArchiveFile() throws {
        let data = try #require(Data(base64Encoded: RealV2Fixtures.archiveV2Base64))
        let decoded = try WindowInstanceCodec.decode(data)

        #expect(decoded.id == UUID(uuidString: "A69AE0F0-DE05-475E-B3BD-5E5F629D2631"))
        #expect(decoded.firstObservedAt == Date(timeIntervalSince1970: 1786966819))
        #expect(decoded.resetsAt == Date(timeIntervalSince1970: 1786977778.329548))
        #expect(decoded.events.isEmpty)
        #expect(decoded.samples.count == 68)
        #expect(decoded.samples.first?.utilization == 30)
        #expect(decoded.samples.first?.timestamp == Date(timeIntervalSince1970: 1786966819))
        #expect(decoded.samples.last?.utilization == 32)
        #expect(decoded.samples.last?.timestamp == Date(timeIntervalSince1970: 1786977718))
    }

    /// v2's CRC covers metadata+payload, so a corrupted PAYLOAD byte is still caught here.
    /// What it can NOT catch — by construction, and precisely the gap v3 closed — is
    /// corruption of `sampleCount` (or `version`) itself, since both sit outside the v2 CRC's
    /// coverage (see `decodeLayoutV2`'s doc comment): a real v2 file with a corrupted sample
    /// count would silently decode a truncated or garbage sample list instead of failing.
    /// That gap is exactly why this codec never writes v2 anymore, only reads it.
    @Test func realV2FileWithCorruptedPayloadByteIsRejected() throws {
        var data = try #require(Data(base64Encoded: RealV2Fixtures.liveV2Base64))
        // Flip a byte well inside the sample payload (offset 184 of 194; payload spans
        // 140...193) — not metadata, not the leading CRC field.
        let flipIndex = data.count - 10
        data[data.index(data.startIndex, offsetBy: flipIndex)] ^= 0xFF

        #expect {
            try WindowInstanceCodec.decode(data)
        } throws: { error in
            (error as? WindowInstanceCodecError) == .crcMismatch
        }
    }
}

// MARK: - Task 4: plateau collapse on archive

@Suite struct PlateauCollapseTests {

    @Test func collapsesRunsOfEqualValuesKeepingFirstAndLast() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            UtilizationSample(utilization: 10, timestamp: base),
            UtilizationSample(utilization: 10, timestamp: base.addingTimeInterval(60)),
            UtilizationSample(utilization: 10, timestamp: base.addingTimeInterval(120)),
            UtilizationSample(utilization: 20, timestamp: base.addingTimeInterval(180)),
            UtilizationSample(utilization: 20, timestamp: base.addingTimeInterval(240)),
        ]
        let collapsed = UsageHistory.collapsePlateaus(samples, gapThreshold: 300)
        #expect(collapsed.map(\.utilization) == [10, 10, 20, 20])
        #expect(collapsed.map(\.timestamp) == [base, base.addingTimeInterval(120), base.addingTimeInterval(180), base.addingTimeInterval(240)])
    }

    @Test func neverCollapsesAcrossAGapAboveThreshold() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            UtilizationSample(utilization: 10, timestamp: base),
            UtilizationSample(utilization: 10, timestamp: base.addingTimeInterval(60)),
            // Gap of 400s (>= 300s gapThreshold) with the SAME value on both sides.
            UtilizationSample(utilization: 10, timestamp: base.addingTimeInterval(460)),
            UtilizationSample(utilization: 10, timestamp: base.addingTimeInterval(520)),
        ]
        let collapsed = UsageHistory.collapsePlateaus(samples, gapThreshold: 300)
        // Both sides of the gap must be preserved as distinct points, not interpolated through.
        #expect(collapsed.map(\.timestamp) == [base, base.addingTimeInterval(60), base.addingTimeInterval(460), base.addingTimeInterval(520)])
    }

    @Test func singleSampleAndAllDistinctValuesAreUnaffected() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let single = [UtilizationSample(utilization: 5, timestamp: base)]
        #expect(UsageHistory.collapsePlateaus(single, gapThreshold: 300) == single)

        let distinct = [
            UtilizationSample(utilization: 1, timestamp: base),
            UtilizationSample(utilization: 2, timestamp: base.addingTimeInterval(60)),
            UtilizationSample(utilization: 3, timestamp: base.addingTimeInterval(120)),
        ]
        #expect(UsageHistory.collapsePlateaus(distinct, gapThreshold: 300) == distinct)
    }

    @Test @MainActor func archiveWindowCollapsesPlateausButLiveInstanceStaysDense() async throws {
        let fixture = UsageHistoryTestFixture()
        let history = fixture.history
        let orgId = UUID().uuidString
        history.switchOrganization(orgId)

        let now = Date()
        let resetsAt = now.addingTimeInterval(600)
        let base = now.addingTimeInterval(-3000)

        // A long plateau of identical values (well within gapThreshold), then a final change.
        let entry1 = makeEntry(key: "five_hour", utilization: 10, resetsAt: resetsAt)
        history.record(entries: [entry1], at: base)
        history.record(entries: [makeEntry(key: "five_hour", utilization: 10, resetsAt: resetsAt)], at: base.addingTimeInterval(60))
        history.record(entries: [makeEntry(key: "five_hour", utilization: 10, resetsAt: resetsAt)], at: base.addingTimeInterval(120))
        history.record(entries: [makeEntry(key: "five_hour", utilization: 50, resetsAt: resetsAt)], at: base.addingTimeInterval(180))

        // Live instance must stay dense (never collapsed) before archiving.
        #expect(history.samples(for: entry1).count == 4)

        await history.archiveWindow(identity: entry1.storageIdentity, resetsAt: resetsAt, windowDuration: 18000, replacingWith: nil)

        let archiveDir = history.archiveDirectory.appendingPathComponent(entry1.storageIdentity)
        let files = try FileManager.default.contentsOfDirectory(at: archiveDir, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let data = try Data(contentsOf: files[0])
        let decoded = try WindowInstanceCodec.decode(data)
        // The 3-sample plateau at 10% collapses to first+last (2 samples), plus the final 50%.
        #expect(decoded.samples.map(\.utilization) == [10, 10, 50])

    }
}
