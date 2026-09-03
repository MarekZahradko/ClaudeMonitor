import Foundation
import Testing
@testable import ClaudeMonitor

/// Covers `RetentionDisplay.isDecimalDigit` / `parsedYears`, added because the retention field
/// previously accepted only the ASCII byte range `0x30...0x39`.
///
/// Two defects had to be fixed together, and testing either alone would have hidden the other:
/// the keystroke guard rejected every character a non-Latin numeric keyboard emits (making the
/// field appear to accept no input at all), while the commit path read `NSTextField.integerValue`,
/// which parses ASCII only — so merely relaxing the guard would have let a user type `٩٩` and
/// silently get 1 stored, because 0 falls through `clampedYears` to the minimum. That is worse
/// than the original rejection, so `parsedYears` exists to read the field's text under the same
/// rules the guard accepts.
@Suite struct RetentionDigitParsingTests {
    // MARK: - isDecimalDigit

    @Test(arguments: ["0", "5", "9", "٠", "٥", "٩", "०", "५", "९", "๐", "๙", "５", "𝟿"])
    func decimalDigitsFromAnyNumberingSystemAreAccepted(character: String) {
        let scalar = Character(character)
        #expect(RetentionDisplay.isDecimalDigit(scalar))
    }

    /// Roman numerals and vulgar fractions are `isNumber == true` but are NOT decimal digits — a
    /// positional parser cannot read them, so accepting them would let the field hold text
    /// `parsedYears` must then reject, leaving the guard and the parser disagreeing.
    @Test(arguments: ["a", "Z", " ", "-", ".", ",", "+", "½", "Ⅳ", "①"])
    func nonDecimalCharactersAreRejected(character: String) {
        let scalar = Character(character)
        #expect(!RetentionDisplay.isDecimalDigit(scalar))
    }

    @Test func multiScalarGraphemeIsRejected() {
        #expect(!RetentionDisplay.isDecimalDigit("7\u{FE0F}"))
        #expect(!RetentionDisplay.isDecimalDigit("👍"))
    }

    // MARK: - parsedYears

    @Test func parsesASCIIDigits() {
        #expect(RetentionDisplay.parsedYears(fromFieldText: "0") == 0)
        #expect(RetentionDisplay.parsedYears(fromFieldText: "00") == 0)
        #expect(RetentionDisplay.parsedYears(fromFieldText: "1") == 1)
        #expect(RetentionDisplay.parsedYears(fromFieldText: "42") == 42)
        #expect(RetentionDisplay.parsedYears(fromFieldText: "99") == 99)
    }

    /// The core regression: these must parse to the SAME numbers as their ASCII equivalents.
    /// `NSTextField.integerValue` returns 0 for every one of them.
    @Test func parsesNonASCIIDecimalDigits() {
        #expect(RetentionDisplay.parsedYears(fromFieldText: "٩٩") == 99)
        #expect(RetentionDisplay.parsedYears(fromFieldText: "٤٢") == 42)
        #expect(RetentionDisplay.parsedYears(fromFieldText: "९९") == 99)
        #expect(RetentionDisplay.parsedYears(fromFieldText: "๙") == 9)
    }

    /// Guards against the naive `Int(text)` implementation, which succeeds on ASCII and returns
    /// nil for Arabic-Indic — the exact asymmetry that caused the bug.
    @Test func nonASCIIParseAgreesWithASCIIForEveryValueInRange() {
        let arabicIndic = ["٠", "١", "٢", "٣", "٤", "٥", "٦", "٧", "٨", "٩"]
        for value in 0...99 {
            let ascii = String(value)
            let translated = String(ascii.map { character in
                Character(arabicIndic[character.wholeNumberValue!])
            })
            #expect(RetentionDisplay.parsedYears(fromFieldText: translated)
                    == RetentionDisplay.parsedYears(fromFieldText: ascii))
        }
    }

    @Test func returnsNilRatherThanZeroForEmptyOrNonDigitText() {
        #expect(RetentionDisplay.parsedYears(fromFieldText: "") == nil)
        #expect(RetentionDisplay.parsedYears(fromFieldText: "abc") == nil)
        #expect(RetentionDisplay.parsedYears(fromFieldText: "1a") == nil)
        #expect(RetentionDisplay.parsedYears(fromFieldText: "a1") == nil)
        #expect(RetentionDisplay.parsedYears(fromFieldText: " 1") == nil)
        #expect(RetentionDisplay.parsedYears(fromFieldText: "1 ") == nil)
        #expect(RetentionDisplay.parsedYears(fromFieldText: "-1") == nil)
        #expect(RetentionDisplay.parsedYears(fromFieldText: "1.5") == nil)
    }

    /// `nil` must stay distinguishable from a real 0: the caller turns `nil` into 0 so
    /// `clampedYears` raises an emptied field to the minimum, but a parser that invented 0 for
    /// `"abc"` would silently accept garbage as a deliberate zero.
    @Test func emptyAndNonDigitAreNilWhileLiteralZeroParses() {
        #expect(RetentionDisplay.parsedYears(fromFieldText: "") == nil)
        #expect(RetentionDisplay.parsedYears(fromFieldText: "0") != nil)
        #expect(RetentionDisplay.parsedYears(fromFieldText: "0") == 0)
    }

    // MARK: - Composition with the clamp

    /// End-to-end for the commit rule the owner specified: 0, 00 and an emptied field all land on
    /// the minimum, and a valid typed value survives untouched — in any numbering system.
    @Test func commitRuleAppliesEqualPerNumberingSystem() {
        func committed(_ text: String) -> Int {
            RetentionDisplay.clampedYears(RetentionDisplay.parsedYears(fromFieldText: text) ?? 0)
        }
        #expect(committed("0") == Constants.History.minRetentionYears)
        #expect(committed("00") == Constants.History.minRetentionYears)
        #expect(committed("") == Constants.History.minRetentionYears)
        #expect(committed("٠") == Constants.History.minRetentionYears)
        #expect(committed("99") == 99)
        #expect(committed("٩٩") == 99)
    }
}
