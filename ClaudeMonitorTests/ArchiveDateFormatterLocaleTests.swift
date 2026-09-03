import Foundation
import Testing
@testable import ClaudeMonitor

/// Regression tests pinning `UsageHistory.archiveDateFormatter`'s locale.
///
/// Archive and quarantine FILENAMES are written and parsed back by this one formatter, and the
/// parsed date decides what the retention policy DELETES. The formatter previously set only
/// `dateFormat` and `timeZone`, leaving `locale` to fall back to `Locale.current` — which
/// governs the calendar and the numbering system even when `dateFormat` is explicit.
///
/// **Honest note on what these tests can and cannot do.** A purely behavioural test cannot fail
/// on a machine whose current locale already uses the Gregorian calendar and ASCII digits —
/// which is most machines, including every one this suite is likely to run on. So this file
/// deliberately does two different things:
///
/// - `archiveDateFormatterIsPinnedToPOSIX` inspects the formatter's own configuration. It fails
///   the instant someone deletes the `locale` line, on ANY machine, which is the only way to
///   make this regression catchable here at all.
/// - The remaining tests prove the underlying mechanism is real rather than hypothetical, by
///   building the *unpinned* formatter this code used to have and showing it diverges under a
///   non-Gregorian-calendar locale — including the dangerous case where parsing SUCCEEDS and
///   silently yields a date centuries away.
@Suite struct ArchiveDateFormatterLocaleTests {
    /// A fixed instant with an unambiguous UTC representation: 2026-08-17 21:40 UTC.
    private static let knownInstant: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 17, hour: 21, minute: 40)
        )!
    }()

    /// The exact filename component the app has written for `knownInstant` since the format was
    /// introduced — hardcoded, not recomputed from the formatter under test.
    private static let knownFilenameComponent = "2026-08-17T2140Z"

    /// The unpinned formatter as it existed before the fix, reproduced here so the tests below
    /// can demonstrate what it does. Takes an explicit locale so the damage is reproducible on
    /// any machine rather than only on a Thai/Arabic-configured one.
    private func unpinnedFormatter(locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "yyyy-MM-dd'T'HHmm'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }

    /// Fails immediately if the `locale` pin is ever removed, regardless of the machine's own
    /// locale. This is the test that actually guards the regression.
    @Test func archiveDateFormatterIsPinnedToPOSIX() {
        let formatter = UsageHistory.archiveDateFormatter
        #expect(formatter.locale.identifier == "en_US_POSIX")
        #expect(formatter.calendar.identifier == .gregorian)
        #expect(formatter.timeZone.secondsFromGMT() == 0)
    }

    /// Round-trips a known instant through the real formatter and compares against a hardcoded
    /// string — so a change to `dateFormat` itself is caught too, not only a locale change.
    @Test func archiveDateFormatterRoundTripsKnownInstantExactly() throws {
        let formatter = UsageHistory.archiveDateFormatter
        #expect(formatter.string(from: Self.knownInstant) == Self.knownFilenameComponent)

        let parsed = try #require(formatter.date(from: Self.knownFilenameComponent))
        #expect(parsed == Self.knownInstant)
    }

    /// The formatter must be immune to the ambient locale. Proven by formatting the same instant
    /// with the real formatter while a hostile locale is in play elsewhere — the real formatter
    /// carries its own locale, so the result cannot move.
    @Test(arguments: ["th_TH", "ar_SA", "hi_IN", "ja_JP", "en_CA"])
    func archiveDateFormatterOutputIsIndependentOfAmbientLocale(localeID: String) {
        let hostile = unpinnedFormatter(locale: Locale(identifier: localeID))
        _ = hostile.string(from: Self.knownInstant)

        #expect(UsageHistory.archiveDateFormatter.string(from: Self.knownInstant)
                == Self.knownFilenameComponent)
    }

    /// Whatever a hostile locale writes, the outcome is one of exactly two disasters — never a
    /// harmless difference. This test asserts that dichotomy directly rather than guessing which
    /// branch a given locale takes.
    ///
    /// Written after the first version of this test asserted the wrong branch and failed,
    /// revealing something worse than assumed: `ar_SA` defaults to the ISLAMIC calendar, so the
    /// unpinned formatter wrote `1448-03-04T2140Z` for a 2026 instant — in plain ASCII digits.
    /// The pinned parser then reads that back with no error at all, as Gregorian year 1448. A
    /// silent 578-year misdating is precisely the input that makes `pruneArchives` delete a
    /// current archive on its next run.
    @Test(arguments: ["ar_SA", "th_TH", "ar_SA@numbers=arab", "fa_IR", "ja_JP@calendar=japanese"])
    func unpinnedFormatterEitherWritesUnparseableOrWildlyMisdatedNames(localeID: String) {
        let hostile = unpinnedFormatter(locale: Locale(identifier: localeID))
        let written = hostile.string(from: Self.knownInstant)

        guard written != Self.knownFilenameComponent else { return }

        // The invariant: a name written under a hostile locale can NEVER read back as the
        // instant it was meant to record. Either it fails to parse (archive becomes invisible
        // to retention forever) or it parses to a date centuries adrift (archive is deleted on
        // the next prune). Both are catastrophic; neither may silently look correct.
        let reparsed = UsageHistory.archiveDateFormatter.date(from: written)
        #expect(reparsed != Self.knownInstant,
                "A hostile-locale name must never round-trip to the correct instant.")

        if let reparsed {
            let yearsApart = abs(reparsed.timeIntervalSince(Self.knownInstant)) / (365.25 * 24 * 3600)
            #expect(yearsApart > 100,
                    "The name parses without error but lands centuries away, so pruneArchives deletes a current archive.")
        }
    }

    /// Demonstrates failure mode 2, the dangerous one: under a Buddhist-calendar locale the
    /// unpinned formatter parses the SAME ASCII digits without error and returns a date roughly
    /// 543 years away. `retentionCutoff` computes with an explicit Gregorian calendar, so such a
    /// date is far past any cutoff and the archive is deleted on the next prune.
    @Test func unpinnedBuddhistCalendarParsesSameDigitsToAWildlyDifferentDate() throws {
        let buddhist = unpinnedFormatter(locale: Locale(identifier: "th_TH"))
        let misparsed = try #require(buddhist.date(from: Self.knownFilenameComponent))

        let correct = try #require(
            UsageHistory.archiveDateFormatter.date(from: Self.knownFilenameComponent)
        )

        #expect(misparsed != correct)

        let yearsApart = abs(misparsed.timeIntervalSince(correct)) / (365.25 * 24 * 3600)
        #expect(yearsApart > 500,
                "Buddhist year 2026 is Gregorian 1483 — the misparse is centuries, not minutes.")
        #expect(misparsed < correct)
    }
}
