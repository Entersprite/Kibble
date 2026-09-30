import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The Punctual probe's printer. Nobody has seen a push yet
/// (`findings.md` §46.6), so the printer cannot know which parts are
/// harmless. It masks by parsing: every string becomes its length unless it
/// is a watched person (then `person N`) or a short lowercase protocol word.
///
/// Session 35 printed a colleague's name and email twice while reading a
/// capture, both times through a pattern that missed a string nested inside
/// a string. These tests pin that case above all.
struct PunctualPushShapeTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func render(_ json: String, people: [String: String] = [:]) throws -> String {
        try PunctualPushShape.render(PBLiteValue(json: Data(json.utf8)), people: people, now: now)
    }

    @Test func namesEmailsURLsAndTokensBecomeTheirLength() throws {
        let rendered = try render(#"["Alice Smith","alice@example.com","https://lh3.example/a","AIzaXYZ12"]"#)
        #expect(rendered == "[s11,s17,s21,s9]")
    }

    /// The case that leaked twice by pattern: a string whose content is
    /// itself JSON. It is parsed and masked, never printed.
    @Test func aStringHoldingJSONIsParsedAndMasked() throws {
        let rendered = try render(#"["[\"Alice Smith\",[\"alice@example.com\",\"availability\"]]"]"#)
        #expect(rendered == #"[json([s11,[s17,"availability"]])]"#)
        #expect(!rendered.contains("Alice"))
        #expect(!rendered.contains("example"))
    }

    @Test func aWatchedIDBecomesItsPersonAndAnyOtherIDItsLength() throws {
        let rendered = try render(
            #"["123456789012345678901","999999999999999999999"]"#,
            people: ["123456789012345678901": "person 3"]
        )
        #expect(rendered == "[person 3,d21]")
    }

    @Test func protocolWordsSurvive() throws {
        #expect(try render(#"["user-state-changes","state","noop","c"]"#)
            == #"["user-state-changes","state","noop","c"]"#)
    }

    /// Anything with a capital, a digit, a space or punctuation other than
    /// `-` and `_` is not a protocol word here, so it is masked.
    @Test func mixedCaseAndDigitsAreNotProtocolWords() throws {
        #expect(try render(#"["Busy","in meeting","prod-09-us","David"]"#) == "[s4,s10,s10,s5]")
    }

    @Test func timesPrintRelativeToTheRunWhetherNumberOrString() throws {
        // 14 minutes before `now`, in microseconds, as pblite sends an int64.
        let micros = String((1_790_000_000 - 840) * 1_000_000)
        let rendered = try render(#"["\#(micros)",1790000300000]"#)
        #expect(rendered == "[@now-14m,@now+5m]")
    }

    @Test func smallNumbersPrintAndLargeOnesOnlyTheirDigitCount() throws {
        #expect(try render("[0,1,15,30000,123456789012345678]") == "[0,1,15,30000,n18]")
    }

    @Test func objectKeysAreMaskedLikeValues() throws {
        #expect(try render(#"{"alice@example.com":1}"#) == "{s17:1}")
    }

    @Test func nullsAndBooleansPrint() throws {
        #expect(try render("[null,true,false]") == "[null,true,false]")
    }
}
