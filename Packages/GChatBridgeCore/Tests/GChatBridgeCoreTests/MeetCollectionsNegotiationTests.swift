import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetCollectionsNegotiationTests {
    private let digest = Array(repeating: "AA", count: 32).joined(separator: ":")

    @Test func collectionsRequiresAnActualBundledSCTPOffer() throws {
        let offer = try MeetAudioOffer(sdp: sdp, collections: true)
        let config = offer.clientConfiguration
        let channel = try MeetProto.payload(8, config)
        #expect(try MeetProto.value(1, channel) == 1)
        #expect(try MeetProto.value(2, channel) == 1)
        #expect(ProtoFieldScan.payloads(ofField: 17, in: config).isEmpty)
        #expect(ProtoFieldScan.payloads(ofField: 3, in: config).count == 1)
        #expect(ProtoFieldScan.payloads(ofField: 4, in: config).count == 1)
        #expect(offer.dataMid == "data")
        #expect(throws: MeetCallWire.WireError.malformedResponse) {
            try MeetAudioOffer(sdp: sdp) // Transport cannot be silently ignored.
        }
        #expect(throws: MeetCallWire.WireError.malformedResponse) {
            try MeetAudioOffer(sdp: sdp.components(separatedBy: "m=application")[0], collections: true)
        }
    }

    @Test func answerUsesTheSameServerTransportForBothOfferedMids() throws {
        let offer = try MeetAudioOffer(sdp: sdp, collections: true)
        let answer = try offer.answer(serverConfiguration: server)
        #expect(answer.contains("a=group:BUNDLE audio data\r\n"))
        let data = try #require(answer.components(separatedBy: "m=application").last)
        #expect(data.hasPrefix(" 9 UDP/DTLS/SCTP webrtc-datachannel\r\n"))
        #expect(data.contains("a=mid:data\r\n"))
        #expect(data.contains("a=sctp-port:5000\r\n"))
        #expect(data.contains("a=setup:passive\r\n"))
        #expect(data.contains("a=ice-ufrag:remote\r\n"))
        #expect(answer.components(separatedBy: "a=ice-pwd:" + String(repeating: "R", count: 27) + "=")
            .count == 3)
        #expect(data.contains("a=candidate:1 1 udp 100 127.0.0.1 3478 typ host\r\n"))
        #expect(!data.contains("a=rtpmap:"))
        #expect(!answer.contains("localpassword"))
    }

    @Test func independentOrMalformedDataTransportsAreRejected() throws {
        for invalid in [
            sdp.replacingOccurrences(of: "a=group:BUNDLE audio data", with: "a=group:BUNDLE audio other"),
            sdp.replacingOccurrences(of: "a=mid:data", with: "a=mid:audio"),
            sdp.replacingOccurrences(of: "a=sctp-port:5000", with: "a=sctp-port:6000"),
            sdp.replacingOccurrences(of: "UDP/DTLS/SCTP", with: "DTLS/SCTP"),
            sdp + "a=ice-ufrag:another\r\n",
            sdp + "m=video 9 UDP/TLS/RTP/SAVPF 96\r\n",
            sdp.replacingOccurrences(
                of: "a=mid:data\r\na=sctp-port:5000",
                with:
                "a=mid:data\r\na=sctp-port:5000\r\na=ice-ufrag:other"
            )
        ] {
            #expect(throws: MeetCallWire.WireError.malformedResponse) {
                try MeetAudioOffer(sdp: invalid, collections: true)
            }
        }
    }

    private var sdp: String {
        [
            "v=0", "a=group:BUNDLE audio data", "m=audio 9 UDP/TLS/RTP/SAVPF 111", "a=mid:audio",
            "a=ice-ufrag:test", "a=ice-pwd:localpassword1234567890", "a=fingerprint:sha-256 " + digest,
            "a=setup:actpass", "a=rtpmap:111 opus/48000/2",
            "a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level",
            "m=application 9 UDP/DTLS/SCTP webrtc-datachannel", "a=mid:data", "a=sctp-port:5000",
            "a=ice-ufrag:test", "a=ice-pwd:localpassword1234567890", "a=fingerprint:sha-256 " + digest,
            "a=setup:actpass"
        ].joined(separator: "\r\n") + "\r\n"
    }

    private var server: Data {
        let fingerprint = MeetProto.string(1, "sha-256") + MeetProto.string(2, digest)
        let dtls = MeetProto.bytes(1, fingerprint) + MeetProto.number(2, 2)
        let stun = MeetProto.string(3, "remote") + MeetProto.string(
            4,
            String(repeating: "R", count: 27) + "="
        )
        let candidate = MeetProto.number(1, 1) + MeetProto.string(2, "127.0.0.1")
            + MeetProto.number(3, 3478) + MeetProto.number(4, 100) + MeetProto.number(5, 1)
        let codec = MeetProto.number(1, 111) + MeetProto.string(2, "opus")
            + MeetProto.number(3, 1) + MeetProto.number(4, 48000) + MeetProto.number(5, 2)
        return MeetProto.bytes(1, dtls) + MeetProto.bytes(2, stun) + MeetProto.bytes(3, candidate)
            + MeetProto.bytes(4, codec)
    }
}
