import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetVideoNegotiationTests {
    @Test func cameraStartsMutedAndHasSeparateReceivingSection() throws {
        let offer = try MeetVideoOffer(sdp: Self.offer)
        #expect(try offer.source == MeetVideoSource(primary: 2001, retransmission: 2002))
        #expect(try offer.audio.audioSource().ssrc == 1001)
        let codecs = ProtoFieldScan.payloads(ofField: 3, in: offer.clientConfiguration)
        let video = try codecs.filter { try MeetProto.value(3, $0) == 2 }
        #expect(video.count == 2)
        #expect(try MeetProto.value(1, video[0]) == 96)
        #expect(try MeetProto.value(5, video[0]) == 1)
        #expect(!ProtoFieldScan.fields(in: offer.clientConfiguration).fields.contains { $0.number == 52 })
        let answer = try offer.answer(serverConfiguration: Self.server)
        #expect(answer.contains("a=group:BUNDLE 0 1 2 3\r\n"))
        #expect(answer.contains("a=mid:1\r\na=recvonly"))
        #expect(answer.contains("a=mid:2\r\na=sendonly"))
        #expect(!answer.contains("a=ssrc:"))
        #expect(answer.contains("a=rtpmap:96 VP8/90000"))
        #expect(answer.contains("a=fmtp:97 apt=96"))
        #expect(!answer.contains("a=rtcp-fb:96 nack pli"))
    }

    @Test func remoteSourceIsBoundOnlyToTheReceivingMid() throws {
        let offer = try MeetVideoOffer(sdp: Self.offer)
        let answer = try offer.answer(
            serverConfiguration: Self.server,
            receiving: MeetVideoSource(primary: 3001, retransmission: 3002)
        )
        let beforeReceiver = try #require(answer.range(of: "a=mid:2"))
        #expect(!answer[..<beforeReceiver.lowerBound].contains("a=ssrc:"))
        #expect(answer.contains("a=ssrc-group:FID 3001 3002"))
        #expect(!answer.contains("2001"))
        #expect(answer.contains("a=msid:kibble-remote video"))
    }

    @Test func independentCameraAndPresentationReceiversKeepTheirOwnMidsAndTrackIdentities() throws {
        let receiver = Self.receiver.map { $0 == "a=mid:2" ? "a=mid:4" : $0 }
        let sdp = (Self.session + ["a=group:BUNDLE 0 1 2 4 3"] + Self.audio + Self.video
            + Self.receiver + receiver + Self.data).joined(separator: "\r\n") + "\r\n"
        let offer = try MeetVideoOffer(sdp: sdp)
        #expect(offer.receivingCapacity == 2)
        let camera = try MeetVideoSource(primary: 3001, retransmission: 3002)
        let screen = try MeetVideoSource(primary: 4001, retransmission: 4002)
        let answer = try offer.answer(serverConfiguration: Self.server, receivingSources: [camera, screen])
        let cameraStart = try #require(answer.range(of: "a=mid:2"))
        let screenStart = try #require(answer.range(of: "a=mid:4"))
        let cameraSection = answer[cameraStart.lowerBound ..< screenStart.lowerBound]
        #expect(cameraSection.contains("a=ssrc-group:FID 3001 3002"))
        #expect(!cameraSection.contains("4001"))
        #expect(answer[screenStart.lowerBound...].contains("a=ssrc-group:FID 4001 4002"))
        #expect(answer.contains("a=msid:kibble-remote-2 video-2"))
        #expect(throws: (any Error).self) {
            try offer.answer(serverConfiguration: Self.server, receivingSources: [camera, camera])
        }
        #expect(throws: (any Error).self) {
            try offer.answer(serverConfiguration: Self.server, receivingSources: [camera, screen, nil])
        }
    }

    @Test func unsafeUnsupportedAndAmbiguousOffersAreRejected() {
        for value in [
            Self.offer.replacingOccurrences(of: "a=mid:2", with: "a=mid:1"),
            Self.offer.replacingOccurrences(of: "a=recvonly", with: "a=sendrecv"),
            Self.offer.replacingOccurrences(of: "VP8/90000", with: "H264/90000"),
            Self.offer.replacingOccurrences(of: "apt=96", with: "apt=98"),
            Self.offer.replacingOccurrences(of: "FID 2001 2002", with: "SIM 2001 2002"),
            Self.offer.replacingOccurrences(of: "a=ssrc:2002", with: "a=ssrc:2003"),
            Self.offer.replacingOccurrences(of: "a=mid:2", with: "a=mid:2\r\na=ice-ufrag:other"),
            Self.offer + String(repeating: "x", count: 100_000)
        ] {
            #expect(throws: (any Error).self) { try MeetVideoOffer(sdp: value) }
        }
    }

    @Test func serverCannotSubstituteUnnegotiatedCodecOrRetransmission() throws {
        let offer = try MeetVideoOffer(sdp: Self.offer)
        let server = Self.server
        let rtx = MeetProto.number(1, 97) + MeetProto.string(2, "rtx") + MeetProto.number(3, 2)
            + MeetProto.number(4, 90000) + MeetProto.number(5, 1)
            + MeetProto.bytes(6, MeetProto.string(1, "apt") + MeetProto.string(2, "98"))
        #expect(throws: (any Error).self) { try offer.answer(serverConfiguration: server + MeetProto.bytes(
            4,
            rtx
        )) }
        let audioOnly = try MeetAudioOffer(sdp: Self.audioOffer, collections: true)
        #expect(throws: (any Error).self) { try offer.answer(serverConfiguration: Self.audioServer) }
        #expect(try audioOnly.answer(serverConfiguration: Self.audioServer).contains("opus/48000/2"))
    }

    @Test func presenterReceiveOnlyAudioDoesNotNegotiateAMicrophoneSender() throws {
        let audio = Self.audio.filter { !$0.hasPrefix("a=ssrc:") && !$0.hasPrefix("a=msid:") }
            .map { $0 == "a=sendrecv" ? "a=recvonly" : $0 }
        let sdp = (Self.session + ["a=group:BUNDLE 0 1 2 3"] + audio + Self.video + Self.receiver + Self.data)
            .joined(separator: "\r\n") + "\r\n"
        let offer = try MeetVideoOffer(sdp: sdp)
        let answer = try offer.answer(serverConfiguration: Self.server)
        #expect(answer.contains("a=mid:0\r\na=sendonly"))
        #expect(throws: (any Error).self) { try offer.audio.audioSource() }
    }

    static let transport = [
        "a=ice-ufrag:test",
        "a=ice-pwd:syntheticpassword12345678",
        "a=fingerprint:sha-256 " + Array(repeating: "AA", count: 32)
            .joined(separator: ":"),
        "a=setup:actpass"
    ]
    static let session = ["v=0", "o=- 1 1 IN IP4 127.0.0.1", "s=-", "t=0 0"]
    static let audio = [
        "m=audio 9 UDP/TLS/RTP/SAVPF 111",
        "a=mid:0",
        "a=sendrecv",
        "a=rtcp-mux",
        "a=rtpmap:111 opus/48000/2",
        "a=msid:local audio",
        "a=ssrc:1001 cname:local",
        "a=ssrc:1001 msid:local audio"
    ] + transport
    static let data = ["m=application 9 UDP/DTLS/SCTP webrtc-datachannel", "a=mid:3", "a=sctp-port:5000"] +
        transport
    static let video = [
        "m=video 9 UDP/TLS/RTP/SAVPF 96 97",
        "a=mid:1",
        "a=sendrecv",
        "a=rtcp-mux",
        "a=rtpmap:96 VP8/90000",
        "a=rtpmap:97 rtx/90000",
        "a=fmtp:97 apt=96",
        "a=rtcp-fb:96 nack",
        "a=rtcp-fb:96 nack pli",
        "a=rtcp-fb:96 ccm fir",
        "a=ssrc:2001 cname:local",
        "a=ssrc:2002 cname:local",
        "a=ssrc-group:FID 2001 2002"
    ] +
        transport
    static let receiver = [
        "m=video 9 UDP/TLS/RTP/SAVPF 96 97",
        "a=mid:2",
        "a=recvonly",
        "a=rtcp-mux",
        "a=rtpmap:96 VP8/90000",
        "a=rtpmap:97 rtx/90000",
        "a=fmtp:97 apt=96"
    ] + transport
    static var offer: String {
        (session + ["a=group:BUNDLE 0 1 2 3"] + audio + video + receiver + data)
            .joined(separator: "\r\n") + "\r\n"
    }

    static var audioOffer: String {
        (session + ["a=group:BUNDLE 0 3"] + audio + data).joined(separator: "\r\n") + "\r\n"
    }

    static var audioServer: Data {
        let fingerprint = MeetProto.string(1, "sha-256") + MeetProto.string(
            2,
            Array(repeating: "BB", count: 32).joined(separator: ":")
        )
        let dtls = MeetProto.bytes(1, fingerprint) + MeetProto.number(2, 2)
        let ice = MeetProto.string(3, "remote") + MeetProto.string(4, "remotepassword12345678901")
        let candidate = MeetProto.number(1, 1) + MeetProto.string(2, "127.0.0.1") + MeetProto.number(3, 3478)
            + MeetProto.number(4, 100) + MeetProto.number(5, 1)
        let opus = MeetProto.number(1, 111) + MeetProto.string(2, "opus") + MeetProto.number(3, 1) + MeetProto
            .number(
                4,
                48000
            ) + MeetProto.number(5, 2)
        return MeetProto.bytes(1, dtls) + MeetProto.bytes(2, ice) + MeetProto.bytes(3, candidate) + MeetProto
            .bytes(
                4,
                opus
            )
    }

    static var server: Data {
        var bytes = audioServer
        for (payload, name) in [(UInt64(96), "VP8"), (97, "rtx")] {
            var codec = MeetProto.number(1, payload) + MeetProto.string(2, name) + MeetProto.number(3, 2)
                + MeetProto.number(4, 90000) + MeetProto.number(5, 1)
            if payload == 97 {
                codec += MeetProto.bytes(
                    6,
                    MeetProto.string(1, "apt") + MeetProto.string(2, "96")
                )
            }
            bytes += MeetProto.bytes(4, codec)
        }
        return bytes
    }
}
