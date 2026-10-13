import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetAudioStreamContextTests {
    @Test func sparseEchoInheritsOnlyThisRequestsSessionAndConference() throws {
        let stream = try makeStream()
        for context in [Data(), MeetProto.string(3, "") + MeetProto.string(5, "")] {
            for variant in [2, 5] {
                let reply = response(variant: variant, context: context)
                let confirmed = try variant == 5
                    ? MeetAudioStreamWire.confirmRegistration(
                        from: reply, stream: stream, ssrc: 4242, muted: false, requestID: 9
                    )
                    : MeetAudioStreamWire.confirmMute(
                        from: reply, stream: stream, muted: false, requestID: 9
                    )
                #expect(confirmed)
            }
        }
        // Source Meet-14 m5g/n5g fills empty parent key getters from the
        // current collection; retain the original own context on later writes.
        let packet = try MeetAudioStreamWire.mute(
            stream: stream, muted: true, requestID: 10, requestHeader: MeetProto.number(1, 1)
        )
        let sent = try MeetProto.payload(4, MeetProto.payload(2, packet))
        #expect(try MeetProto.text(3, sent) == "native")
        #expect(try MeetProto.text(5, sent) == "conference")
    }

    @Test func sparseContextDoesNotHideForeignOrMalformedValues() throws {
        let invalid = [
            MeetProto.string(3, "foreign"), MeetProto.string(5, "foreign"),
            MeetProto.string(3, "") + MeetProto.string(3, ""),
            MeetProto.string(5, "") + MeetProto.string(5, "conference"),
            MeetProto.number(3, 0), MeetProto.number(5, 0),
            MeetProto.bytes(3, Data([0xFF])), MeetProto.string(5, "line\nbreak")
        ]
        for context in invalid {
            for variant in [2, 5] {
                #expect(throws: MeetCallWire.WireError.malformedResponse) {
                    if variant == 5 {
                        try MeetAudioStreamWire.confirmRegistration(
                            from: response(variant: variant, context: context), stream: makeStream(),
                            ssrc: 4242, muted: false, requestID: 9
                        )
                    } else {
                        try MeetAudioStreamWire.confirmMute(
                            from: response(variant: variant, context: context), stream: makeStream(),
                            muted: false, requestID: 9
                        )
                    }
                }
            }
        }
        #expect(throws: MeetCallWire.WireError.malformedResponse) {
            try MeetAudioStreamWire.confirmRegistration(
                from: response(variant: 5, context: Data()), stream: makeStream(),
                ssrc: 4243, muted: false, requestID: 9
            )
        }
    }

    private func makeStream() throws -> MeetAudioStreamWire.Stream {
        try .init(mediaSession: "mediasessions/native", conferenceID: "conference", streamID: "track")
    }

    private func response(variant: Int, context: Data) -> Data {
        let echo = MeetProto.number(1, 2) + MeetProto.number(2, 1) + MeetProto.string(4, "track")
            + context + MeetProto.bytes(8, MeetProto.bytes(1, MeetProto.unsigned(4242)))
            + MeetProto.bytes(10, MeetProto.number(1, 0))
        return MeetProto.number(1, 9) + MeetProto.bytes(4, Data()) + MeetProto.bytes(
            UInt64(variant), MeetProto.bytes(1, MeetProto.number(1, 1)) + MeetProto.bytes(4, echo)
        )
    }
}
