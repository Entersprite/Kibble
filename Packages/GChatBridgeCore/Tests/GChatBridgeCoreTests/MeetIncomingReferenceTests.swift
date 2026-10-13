import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetIncomingReferenceTests {
    private let space = MeetCallWire.Space(
        name: "spaces/opaque-secret", code: "abc-defg-hij",
        url: URL(string: "https://meet.google.com/abc-defg-hij")!
    )

    @Test func equivalentResourceFormsMatchExactly() {
        #expect(MeetIncomingReference.match("abc-defg-hij", space: space) == .code)
        #expect(MeetIncomingReference.match("spaces/opaque-secret", space: space) == .spaceName)
        #expect(MeetIncomingReference.match("opaque-secret", space: space) == .spaceID)
        #expect(MeetIncomingReference.match("https://meet.google.com/abc-defg-hij", space: space) == .url)
    }

    @Test(arguments: [
        "",
        "another-secret",
        "spaces/another-secret",
        "spaces/opaque-secret/devices/x",
        " opaque-secret",
        "OPAQUE-SECRET",
        "https://evil.example/abc-defg-hij",
        "https://meet.google.com/abc-defg-hij?extra=1"
    ])
    func otherReferencesAreNotCoercedIntoTheResolvedCall(_ reference: String) {
        #expect(MeetIncomingReference.match(reference, space: space) == .none)
        #expect(!MeetIncomingReference.diagnostic(reference, space: space).contains("secret"))
        #expect(!MeetIncomingReference.diagnostic(reference, space: space).contains("abc-defg-hij"))
    }

    @Test func referenceDiagnosticsDoNotIncludeURLsOrResourceIDs() {
        #expect(MeetIncomingReference.diagnostic("opaque-secret", space: space)
            == "Incoming call reference: 13 bytes; bare identifier; bare space ID")
        #expect(MeetIncomingReference.diagnostic("other-secret", space: space)
            == "Incoming call reference: 12 bytes; bare identifier; no matching reference")
    }
}

extension MeetIncomingReferenceTests {
    @Test func compactMeetingCodeMatchesOnlyItsPreciselyFormattedEquivalent() {
        #expect(MeetIncomingReference.match("abcdefghij", space: space) == .compactCode)
        #expect(MeetIncomingReference.match("Abcdefghij", space: space) == .none)
        #expect(MeetIncomingReference.match("abcdefghik", space: space) == .none)
        let malformed = MeetCallWire.Space(name: "spaces/id", code: "ab-cdefg-hij", url: space.url)
        #expect(MeetIncomingReference.match("abcdefghij", space: malformed) == .none)
    }
}
