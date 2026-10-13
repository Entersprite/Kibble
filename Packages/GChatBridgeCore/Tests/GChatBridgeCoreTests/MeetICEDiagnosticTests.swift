import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetICEDiagnosticTests {
    @Test func shapesUseFixedLabelsAndNeverCredentialValues() {
        let padded = String(repeating: "U", count: 27) + "="
        let password = String(repeating: "P", count: 27) + "="
        let first = MeetAudioOffer.iceDiagnostics(serverConfiguration: configuration(padded, password))
        #expect(first == [
            "Native ICE ufrag: bytes 28; alphabet Base64; padding terminal 1; supported yes",
            "Native ICE password: bytes 28; alphabet Base64; padding terminal 1; supported yes"
        ])
        for (value, alphabet, padding) in [
            ("private:credential!sentinel", "other ASCII", "none"),
            ("private credential\r\nsentinel", "whitespace/control or non-ASCII", "none"),
            ("privateécredential", "whitespace/control or non-ASCII", "none"),
            ("private=credential", "Base64", "interior"),
            ("privatecredential===", "Base64", "invalid")
        ] {
            let report = MeetAudioOffer.iceDiagnostics(serverConfiguration: configuration(value, password))
                .joined(separator: "\n")
            #expect(report.contains("alphabet " + alphabet))
            #expect(report.contains("padding " + padding))
            #expect(report.contains("supported no"))
            #expect(!report.contains(value))
            #expect(!report.contains("private"))
            #expect(!report.contains(password))
        }
        #expect(!first.joined().contains(padded))
        #expect(!first.joined().contains(password))
    }

    @Test func ownerReportedURLSafeShapeIsSupportedWithoutReportingTheCredential() {
        let fragment = String(repeating: "U", count: 26) + "-_"
        let password = String(repeating: "P", count: 27) + "="
        let report = MeetAudioOffer.iceDiagnostics(serverConfiguration: configuration(fragment, password))
        #expect(report == [
            "Native ICE ufrag: bytes 28; alphabet URL-safe Base64; padding none; supported yes",
            "Native ICE password: bytes 28; alphabet Base64; padding terminal 1; supported yes"
        ])
        #expect(!report.joined().contains(fragment))
        #expect(!report.joined().contains(password))
    }

    @Test func malformedAndDuplicateFieldsStayDistinctWithoutRawParserErrors() {
        let password = MeetProto.string(4, "private-password-sentinel")
        let cases: [(Data, String)] = [
            (password, "missing field"),
            (MeetProto.string(3, "first") + MeetProto.string(3, "second") + password, "duplicate field"),
            (MeetProto.number(3, 1) + password, "wrong field type"),
            (MeetProto.bytes(3, Data([0xC3])) + password, "invalid UTF-8")
        ]
        for (stun, expected) in cases {
            let report = MeetAudioOffer.iceDiagnostics(serverConfiguration: MeetProto.bytes(2, stun))
            #expect(report[0].contains(expected))
            #expect(!report.joined().contains("private"))
        }
        #expect(MeetAudioOffer.iceDiagnostics(serverConfiguration: MeetProto.bytes(2, Data([0x80])))
            == ["Native ICE diagnostic: malformed STUN configuration"])
        let large = MeetAudioOffer.iceDiagnostics(serverConfiguration: configuration(
            String(repeating: "A", count: 257),
            "short"
        ))
        #expect(large[0].contains("bytes >256"))
        #expect(large[1].contains("bytes 5"))
        #expect(large.allSatisfy { $0.contains("supported no") })
    }

    @Test func remotePaddingRespectsEachFieldsOwnMinimum() {
        #expect(MeetAudioOffer.validRemoteCredential("QQ==", minimum: 4))
        #expect(!MeetAudioOffer.validRemoteCredential("QQ==", minimum: 22))
        #expect(!MeetAudioOffer.validRemoteCredential("A===", minimum: 4))
        #expect(!MeetAudioOffer.validRemoteCredential("AAAA=", minimum: 4))
        #expect(!MeetAudioOffer.validRemoteCredential("AA=A", minimum: 4))
    }

    private func configuration(_ fragment: String, _ password: String) -> Data {
        MeetProto.bytes(2, MeetProto.string(3, fragment) + MeetProto.string(4, password))
    }
}
