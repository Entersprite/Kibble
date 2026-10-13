import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetAudioNegotiationTests {
    private let digest = Array(repeating: "AA", count: 32).joined(separator: ":")

    @Test func offerUsesItsOwnFingerprintCredentialsCodecAndExtensions() throws {
        let parsed = try MeetAudioOffer(sdp: offer)
        let configuration = parsed.clientConfiguration
        let dtls = try MeetProto.payload(1, configuration)
        #expect(try MeetProto.value(2, dtls) == 3)
        #expect(try MeetProto.value(3, dtls) == 1)
        #expect(try MeetProto.value(5, dtls) == 1)
        #expect(try MeetProto.value(36, configuration) == 2)
        #expect(ProtoFieldScan.fields(in: configuration).fields.allSatisfy { $0.number != 44 })
        let fingerprint = try MeetProto.payload(1, dtls)
        #expect(try MeetProto.text(2, fingerprint) == digest)
        let stun = try MeetProto.payload(2, configuration)
        #expect(try MeetProto.text(3, stun) == "test")
        #expect(try MeetProto.text(4, stun) == "syntheticpassword12345678")
        let codec = try MeetProto.payload(3, configuration)
        #expect(try MeetProto.value(1, codec) == 111)
        #expect(try MeetProto.text(2, codec) == "opus")
        #expect(ProtoFieldScan.payloads(ofField: 6, in: codec).count == 2)
        #expect(ProtoFieldScan.payloads(ofField: 4, in: configuration).count == 1)
    }

    @Test func srtpPreferenceComesFromTheEngineAndAudioOutputIsNotDisabled() throws {
        for (suite, expected) in [
            (MeetAudioOffer.SRTPSuite.aes128SHA180, UInt64(1)),
            (.aeadAES128GCM, 2), (.aeadAES256GCM, 3)
        ] {
            let parsed = try MeetAudioOffer(sdp: offer, srtpSuite: suite)
            let dtls = try MeetProto.payload(1, parsed.clientConfiguration)
            #expect(try MeetProto.value(3, dtls) == expected)
            #expect(ProtoFieldScan.fields(in: parsed.clientConfiguration).fields
                .allSatisfy { $0.number != 44 })
        }
    }

    @Test func answerPreservesMidAndNegotiatesOnlyAcceptedCodecAndExtension() throws {
        let parsed = try MeetAudioOffer(sdp: offer)
        let answer = try parsed.answer(serverConfiguration: server())
        #expect(answer.contains("a=mid:0\r\n"))
        #expect(answer.contains("a=setup:passive\r\n"))
        #expect(answer.contains("a=ice-ufrag:remote\r\n"))
        #expect(answer.contains("a=candidate:1 1 udp 100 127.0.0.1 3478 typ host\r\n"))
        #expect(answer.contains("a=rtpmap:111 opus/48000/2\r\n"))
        #expect(answer.contains("a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level\r\n"))
        #expect(!answer.contains("syntheticpassword12345678"))
    }

    @Test func missingOrUnsafeOrUnofferedAnswerFailsBeforeNativeApplication() throws {
        let parsed = try MeetAudioOffer(sdp: offer)
        for (data, failure) in [
            (server(role: 3), MeetAudioOffer.AnswerFailure.dtls), (server(port: 70000), .candidates),
            (server(payload: 99), .codecs),
            (server(address: "127.0.0.1\r\na=setup:active"), .candidates),
            (server() + Data([0x80]), .configuration)
        ] {
            #expect(throws: failure) {
                try parsed.answer(serverConfiguration: data)
            }
        }
    }

    @Test func remotePaddedPasswordIsPreservedButCannotEnterALocalOffer() throws {
        let parsed = try MeetAudioOffer(sdp: offer)
        for password in [String(repeating: "A", count: 27) + "=", String(repeating: "A", count: 26) + "=="] {
            let answer = try parsed.answer(serverConfiguration: server(password: password))
            #expect(answer.contains("a=ice-pwd:\(password)\r\n"))
            let local = offer.replacingOccurrences(of: "syntheticpassword12345678", with: password)
            #expect(throws: MeetCallWire.WireError.malformedResponse) { try MeetAudioOffer(sdp: local) }
        }
    }

    @Test func remotePaddedFragmentAndPasswordAreBothPreserved() throws {
        let parsed = try MeetAudioOffer(sdp: offer)
        let fragment = String(repeating: "U", count: 27) + "="
        let password = String(repeating: "P", count: 27) + "="
        let answer = try parsed.answer(serverConfiguration: server(password: password, ufrag: fragment))
        #expect(answer.contains("a=ice-ufrag:\(fragment)\r\n"))
        #expect(answer.contains("a=ice-pwd:\(password)\r\n"))
        #expect(throws: MeetCallWire.WireError.malformedResponse) {
            try MeetAudioOffer(sdp: offer.replacingOccurrences(
                of: "a=ice-ufrag:test",
                with: "a=ice-ufrag:" + fragment
            ))
        }
    }

    @Test func remoteURLSafeCredentialsArePreservedWithoutChangingTheLocalOfferRules() throws {
        let parsed = try MeetAudioOffer(sdp: offer)
        for fragment in [
            String(repeating: "U", count: 26) + "-_",
            String(repeating: "U", count: 25) + "-_="
        ] {
            for password in [
                String(repeating: "P", count: 26) + "-_",
                String(repeating: "P", count: 25) + "-_="
            ] {
                let answer = try parsed.answer(serverConfiguration: server(
                    password: password,
                    ufrag: fragment
                ))
                #expect(answer.contains("a=ice-ufrag:\(fragment)\r\n"))
                #expect(answer.contains("a=ice-pwd:\(password)\r\n"))
                #expect(throws: MeetCallWire.WireError.malformedResponse) {
                    try MeetAudioOffer(sdp: offer.replacingOccurrences(
                        of: "a=ice-ufrag:test", with: "a=ice-ufrag:" + fragment
                    ))
                }
                #expect(throws: MeetCallWire.WireError.malformedResponse) {
                    try MeetAudioOffer(sdp: offer.replacingOccurrences(
                        of: "syntheticpassword12345678", with: password
                    ))
                }
            }
        }
    }

    @Test func unsafeOrMalformedPasswordPaddingIsRejectedWithAFixedStage() throws {
        let parsed = try MeetAudioOffer(sdp: offer)
        for password in [
            "=AAAAAAAAAAAAAAAAAAAAAAAAAAA", "AAAAAAAAAAAAAA=AAAAAAAAAAAA=",
            "AAAAAAAAAAAAAAAAAAAAAAAAA===", "AAAAAAAAAAAAAAAAAAAAAAAAAAA= ",
            "AAAAAAAAAAAAAAAAAAAAAAAAAAA=\r\na=setup:active", "short=",
            String(repeating: "A", count: 259) + "=", "AAAAAAAAAAAAAAAAAAAAAAAAA+-=",
            "AAAAAAAAAAAAAAAAAAAAAAAAA/_="
        ] {
            #expect(throws: MeetAudioOffer.AnswerFailure.ice) {
                try parsed.answer(serverConfiguration: server(password: password))
            }
        }
    }

    @Test func otherMediaAndDuplicateOrMissingCredentialsAreNotSilentlyMapped() throws {
        for sdp in [
            offer + "m=video 9 UDP/TLS/RTP/SAVPF 96\r\n",
            offer + "a=mid:another\r\n",
            offer.replacingOccurrences(of: "a=ice-ufrag:test", with: "a=ice-ufrag:x"),
            offer.replacingOccurrences(of: "sha-256", with: "sha-1"),
            offer.replacingOccurrences(of: "a=setup:actpass", with: "a=setup:active")
        ] {
            #expect(throws: MeetCallWire.WireError.malformedResponse) { try MeetAudioOffer(sdp: sdp) }
        }
    }

    @Test func legacyTelephonyCodecsAndIncorrectOpusProfilesCannotReachMeet() throws {
        for codec in ["PCMU/8000", "PCMA/8000", "G722/8000", "CN/8000", "telephone-event/48000"] {
            let sdp = offer.replacingOccurrences(of: "RTP/SAVPF 111", with: "RTP/SAVPF 111 112")
                + "a=rtpmap:112 \(codec)\r\n"
            #expect(throws: MeetCallWire.WireError.malformedResponse) { try MeetAudioOffer(sdp: sdp) }
        }
        for codec in ["opus/8000/2", "opus/48000/1", "red/48000/1"] {
            let sdp = offer.replacingOccurrences(of: "opus/48000/2", with: codec)
            #expect(throws: MeetCallWire.WireError.malformedResponse) { try MeetAudioOffer(sdp: sdp) }
        }
    }

    @Test func redKeepsItsValuelessFormatParameterInBothDirections() throws {
        let sdp = offer.replacingOccurrences(of: "RTP/SAVPF 111", with: "RTP/SAVPF 111 63")
            + "a=rtpmap:63 red/48000/2\r\na=fmtp:63 111/111\r\n"
        let parsed = try MeetAudioOffer(sdp: sdp)
        let red = try #require(ProtoFieldScan.payloads(ofField: 3, in: parsed.clientConfiguration).last)
        let entry = try MeetProto.payload(6, red)
        #expect(try MeetProto.payload(1, entry).isEmpty)
        #expect(try MeetProto.text(2, entry) == "111/111")
        let response = MeetProto.number(1, 63) + MeetProto.string(2, "red") + MeetProto.number(3, 1)
            + MeetProto.number(4, 48000) + MeetProto.number(5, 2) + MeetProto.bytes(6, entry)
        let answer = try parsed.answer(serverConfiguration: server() + MeetProto.bytes(4, response))
        #expect(answer.contains("a=fmtp:63 111/111\r\n"))
    }

    private var offer: String {
        [
            "v=0", "m=audio 9 UDP/TLS/RTP/SAVPF 111", "a=mid:0", "a=sendrecv",
            "a=ice-ufrag:test", "a=ice-pwd:syntheticpassword12345678",
            "a=fingerprint:sha-256 " + digest, "a=setup:actpass", "a=rtpmap:111 opus/48000/2",
            "a=fmtp:111 minptime=10;useinbandfec=1",
            "a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level"
        ].joined(separator: "\r\n") + "\r\n"
    }

    private func server(
        role: UInt64 = 2, port: UInt64 = 3478, payload: UInt64 = 111, address: String = "127.0.0.1",
        password: String = "remotepassword1234567890", ufrag: String = "remote"
    ) -> Data {
        let fingerprint = MeetProto.string(1, "sha-256") + MeetProto.string(2, digest)
        let dtls = MeetProto.bytes(1, fingerprint) + MeetProto.number(2, role)
        let stun = MeetProto.string(3, ufrag) + MeetProto.string(4, password)
        let candidate = MeetProto.number(1, 1) + MeetProto.string(2, address)
            + MeetProto.number(3, port) + MeetProto.number(4, 100) + MeetProto.number(5, 1)
        let codec = MeetProto.number(1, payload) + MeetProto.string(2, "opus")
            + MeetProto.number(3, 1) + MeetProto.number(4, 48000) + MeetProto.number(5, 2)
        let header = MeetProto.number(1, 1)
            + MeetProto.string(2, "urn:ietf:params:rtp-hdrext:ssrc-audio-level")
            + MeetProto.number(3, 1) + MeetProto.number(4, 1)
        return MeetProto.bytes(1, dtls) + MeetProto.bytes(2, stun) + MeetProto.bytes(3, candidate)
            + MeetProto.bytes(4, codec) + MeetProto.bytes(5, header)
    }
}
