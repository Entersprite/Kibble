import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetAudioSourceTests {
    @Test func registrationDiagnosticsIdentifyMismatchesWithoutValues() throws {
        let stream = try MeetAudioStreamWire.Stream(
            mediaSession: "mediasessions/session-sentinel", conferenceID: "conference-sentinel",
            streamID: "track-sentinel"
        )
        let fields = [
            MeetProto.number(1, 2), MeetProto.number(2, 1), MeetProto.string(3, "session-sentinel"),
            MeetProto.string(4, "track-sentinel"), MeetProto.string(5, "conference-sentinel"),
            MeetProto.bytes(8, MeetProto.bytes(1, MeetProto.unsigned(4242))),
            MeetProto.bytes(10, MeetProto.number(1, 0))
        ]
        let replacements = [
            ("direction", MeetProto.number(1, UInt64.max)),
            ("media kind", MeetProto.number(2, 2)),
            ("session", MeetProto.string(3, "foreign-session-sentinel")),
            ("stream", MeetProto.string(4, "foreign-track-sentinel")),
            ("conference", MeetProto.string(5, "foreign-conference-sentinel")),
            ("SSRC", MeetProto.bytes(8, MeetProto.bytes(1, MeetProto.unsigned(4243)))),
            ("mute", MeetProto.bytes(10, MeetProto.number(1, 1)))
        ]
        for (index, replacement) in replacements.enumerated() {
            var changed = fields
            changed[index] = replacement.1
            let reply = MeetProto.number(1, 7) + MeetProto.bytes(4, Data()) + MeetProto.bytes(
                5, MeetProto.bytes(1, MeetProto.number(1, 1))
                    + MeetProto.bytes(4, changed.reduce(Data(), +))
            )
            let diagnostic = MeetAudioStreamWire.registrationDiagnostic(
                from: reply, stream: stream, ssrc: 4242, muted: false, requestID: 7
            )
            #expect(diagnostic.contains(replacement.0 + " differs"))
            #expect(!diagnostic.contains("sentinel"))
            #expect(!diagnostic.contains("4242"))
            #expect(!diagnostic.contains("4243"))
            #expect(!diagnostic.contains(String(UInt64.max)))
            #expect(throws: MeetCallWire.WireError.malformedResponse) {
                try MeetAudioStreamWire.confirmRegistration(
                    from: reply, stream: stream, ssrc: 4242, muted: false, requestID: 7
                )
            }
        }
        #expect(MeetAudioStreamWire.registrationDiagnostic(
            from: Data([0xFF]), stream: stream, ssrc: 4242, muted: false, requestID: 7
        ) == "reply structure invalid")
    }

    @Test func sourceUsesOnlyActualAudioSSRCAndTrack() throws {
        let offer = try MeetAudioOffer(sdp: sdp, collections: true, streamControl: true)
        let source = try offer.audioSource()
        #expect(source.streamID == "track")
        #expect(source.ssrc == 4242)
        let channel = try MeetProto.payload(17, offer.clientConfiguration)
        #expect(try MeetProto.text(1, channel) == "dcrpc")
        #expect(try MeetProto.value(2, channel) == 1)
        #expect(try MeetProto.value(4, channel) == 1)
        #expect(try MeetProto.value(7, channel) == 1)
    }

    @Test func rejectsMissingOrAmbiguousSourceAndNoSCTP() throws {
        for invalid in [
            sdp.replacingOccurrences(of: "a=ssrc:4242 cname:synthetic\r\n", with: ""),
            sdp.replacingOccurrences(of: "a=ssrc:4242", with: "a=ssrc:0"),
            sdp.replacingOccurrences(of: "a=ssrc:4242", with: "a=ssrc:4294967296"),
            sdp.replacingOccurrences(
                of: "a=ssrc:4242 cname:synthetic",
                with: "a=ssrc:4242 cname:synthetic\r\na=ssrc:4243 cname:other"
            ),
            sdp.replacingOccurrences(
                of: "a=msid:stream track",
                with: "a=msid:stream track\r\na=msid:stream other"
            )
        ] {
            let offer = try MeetAudioOffer(sdp: invalid, collections: true)
            #expect(throws: MeetCallWire.WireError.malformedResponse) { try offer.audioSource() }
        }
        #expect(throws: MeetCallWire.WireError.invalidIdentifier) {
            try rejectUnbundledControl()
        }
    }

    @Test func registrationEchoMustMatchSSRCAndBothSuccessLayers() throws {
        let stream = try MeetAudioStreamWire.Stream(
            mediaSession: "mediasessions/native",
            conferenceID: "conference",
            streamID: "track"
        )
        let request = try MeetAudioStreamWire.register(
            stream: stream, ssrc: 4242, muted: false, requestID: 1, requestHeader: MeetProto.number(1, 1)
        )
        let value = try MeetProto.payload(4, MeetProto.payload(4, request))
        let reply = MeetProto.number(1, 1) + MeetProto.bytes(4, Data())
            + MeetProto.bytes(5, MeetProto.bytes(1, MeetProto.number(1, 1)) + MeetProto.bytes(4, value))
        try MeetAudioStreamWire.confirmRegistration(
            from: reply,
            stream: stream,
            ssrc: 4242,
            muted: false,
            requestID: 1
        )
        #expect(throws: MeetCallWire.WireError.malformedResponse) {
            try MeetAudioStreamWire.confirmRegistration(
                from: reply,
                stream: stream,
                ssrc: 4243,
                muted: false,
                requestID: 1
            )
        }
        #expect(MeetAudioStreamWire.matchesRequest(reply, requestID: 1))
        #expect(!MeetAudioStreamWire.matchesRequest(reply, requestID: 2))
    }

    private func rejectUnbundledControl() throws {
        _ = try MeetAudioOffer(sdp: sdp.components(separatedBy: "m=application")[0], streamControl: true)
    }

    private var sdp: String {
        let digest = Array(repeating: "AA", count: 32).joined(separator: ":")
        return [
            "v=0", "a=group:BUNDLE 0 1", "m=audio 9 UDP/TLS/RTP/SAVPF 111", "a=mid:0",
            "a=ice-ufrag:test", "a=ice-pwd:nativepassword1234567890", "a=fingerprint:sha-256 " + digest,
            "a=setup:actpass", "a=rtpmap:111 opus/48000/2", "a=msid:stream track",
            "a=ssrc:4242 cname:synthetic",
            "m=application 9 UDP/DTLS/SCTP webrtc-datachannel", "a=mid:1", "a=sctp-port:5000",
            "a=ice-ufrag:test", "a=ice-pwd:nativepassword1234567890", "a=fingerprint:sha-256 " + digest,
            "a=setup:actpass"
        ].joined(separator: "\r\n") + "\r\n"
    }
}
