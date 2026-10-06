import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `--probe=people`'s pure parts: what a `ListAutocompletions` answer holds,
/// counted and never printed, and the SHA-1 the `SAPISIDHASH` needs. The
/// answer's positions are the owner's capture's (`findings.md` §57); every
/// value is invented.
struct PeopleProbeReportTests {
    private static let answer = #"""
    [[["person1@example.invalid",null,"PERSON",["123456789012345678901",[null]]],\#
    ["person2@example.invalid",null,"PERSON",["123456789012345678902",[null]]],\#
    ["group@example.invalid",null,"GOOGLE_GROUP",null,["987654321098765432109"]],\#
    ["contacts",null,"AUTOCOMPLETE_GROUP",{"11":[]}],\#
    ["odd",null,"SOMETHING_NEW"]]]
    """#

    @Test func theAnswerIsCountedByKind() throws {
        let shapes = try #require(PeopleProbeReport.shapes(of: Data(Self.answer.utf8)))
        #expect(shapes.results == 5)
        #expect(shapes.kinds == ["PERSON": 2, "GOOGLE_GROUP": 1, "AUTOCOMPLETE_GROUP": 1, "SOMETHING_NEW": 1])
        #expect(shapes.personIDs == ["123456789012345678901", "123456789012345678902"])
        #expect(shapes.personEmails == ["person1@example.invalid", "person2@example.invalid"])
    }

    @Test func theLinesNameNoIDAndNoEmail() throws {
        let shapes = try #require(PeopleProbeReport.shapes(of: Data(Self.answer.utf8)))
        let text = PeopleProbeReport.lines(for: shapes).joined(separator: "\n")
        #expect(text.contains("results 5"))
        #expect(text.contains("PERSON 2"))
        #expect(text.contains("PERSON with a 21-digit id 2"))
        #expect(!text.contains("example.invalid"))
        #expect(!text.contains("12345678901234567890"))
    }

    @Test func anXSSIPrefixIsTolerated() {
        #expect(PeopleProbeReport.shapes(of: Data((")]}'\n" + Self.answer).utf8))?.results == 5)
    }

    @Test func somethingElseIsNotAnAnswer() {
        #expect(PeopleProbeReport.shapes(of: Data("<html>".utf8)) == nil)
    }

    /// Google's `json+protobuf` error is `[code, "message", …]`; its message
    /// is a fixed English sentence, printed only when it looks like one.
    @Test func anErrorBodyGivesItsCodeAndSentence() {
        let body = Data(#"[401,"Request had invalid authentication credentials.",[]]"#.utf8)
        #expect(PeopleProbeReport.errorSummary(body) == "401 Request had invalid authentication credentials.")
    }

    @Test func anErrorSentenceWithAnAddressIsNotPrinted() {
        let body = Data(#"[403,"Denied for someone@example.invalid",[]]"#.utf8)
        #expect(PeopleProbeReport.errorSummary(body) == "403 (message withheld, 34 chars)")
    }

    /// `python3 -c 'import hashlib; print(hashlib.sha1(b"1700000000 sap-1
    /// https://chat.google.com").hexdigest())'`
    @Test func sha1MatchesAKnownVector() {
        #expect(PeopleProbeReport.sha1Hex("1700000000 sap-1 https://chat.google.com")
            == "0cdf34bd486e3b4f14ed3eb372ae19228144c08d")
    }
}
