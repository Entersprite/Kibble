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

    // MARK: - Written as it goes

    /// A minimal in-memory `SecretStorage`, copied rather than shared, as
    /// `APIProbeReportTests` explains.
    private final class EmptySecretStorage: SecretStorage, @unchecked Sendable {
        func read(account _: String) throws -> Data? {
            nil
        }

        func write(_: Data, account _: String) throws {}
        func delete(account _: String) throws {}
    }

    private final class Flushes: @unchecked Sendable {
        private let lock = NSLock()
        private var texts: [String] = []

        func append(_ text: String) {
            lock.withLock { texts.append(text) }
        }

        var all: [String] {
            lock.withLock { texts }
        }
    }

    /// A probe that hangs must leave a file ending at the step that hung, so
    /// the header is written before the first await and the whole text after
    /// the last (session 51: a run that showed nothing and wrote nothing).
    @Test func theReportIsFlushedBeforeTheFirstStepAndAtTheEnd() async throws {
        let flushes = Flushes()
        let text = await PeopleProbeReport.run(
            store: KeychainCredentialStore(storage: EmptySecretStorage(), account: "people-test"),
            transport: ScriptedTransport([]),
            endpoints: ChatEndpoints(),
            flush: { flushes.append($0) }
        )
        let first = try #require(flushes.all.first)
        #expect(first.contains("gchat people probe"))
        #expect(!first.contains("No session"))
        #expect(flushes.all.last == text)
        #expect(text.contains("No session"))
    }
}
