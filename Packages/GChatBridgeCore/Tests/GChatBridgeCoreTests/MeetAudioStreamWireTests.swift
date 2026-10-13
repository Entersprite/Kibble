import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetAudioStreamWireTests {
    @Test func acceptsStatusOnlyAcknowledgementsWithoutClaimingAnEcho() throws {
        // Meet-14 Bah/vWg accept both success statuses; x5g/z5g return
        // the repeated stream list, which C5g allows to be empty.
        for variant in [2, 5] {
            let data = MeetProto.number(1, 9) + MeetProto.bytes(4, Data())
                + MeetProto.bytes(UInt64(variant), MeetProto.bytes(1, MeetProto.number(1, 1)))
            if variant == 5 {
                let echoed = try MeetAudioStreamWire.confirmRegistration(
                    from: data, stream: makeStream(), ssrc: 4242, muted: false, requestID: 9
                )
                #expect(!echoed)
            } else {
                let echoed = try MeetAudioStreamWire.confirmMute(
                    from: data, stream: makeStream(), muted: true, requestID: 9
                )
                #expect(!echoed)
            }
            #expect(MeetAudioStreamWire.replyDiagnostic(data).contains("stream echoes 0"))
            for invalid in [
                data + MeetProto.number(1, 9),
                MeetProto.number(1, 9) + MeetProto.bytes(4, MeetProto.number(1, 3))
                    + MeetProto.bytes(UInt64(variant), MeetProto.bytes(1, MeetProto.number(1, 1))),
                MeetProto.number(1, 10) + MeetProto.bytes(4, Data())
                    + MeetProto.bytes(UInt64(variant), MeetProto.bytes(1, MeetProto.number(1, 1))),
                MeetProto.number(1, 9) + MeetProto.bytes(4, Data())
                    + MeetProto.bytes(UInt64(variant), MeetProto.bytes(1, MeetProto.number(1, 0))),
                MeetProto.number(1, 9) + MeetProto.bytes(4, Data())
                    + MeetProto.bytes(
                        UInt64(variant),
                        MeetProto.bytes(1, MeetProto.number(1, 1))
                            + MeetProto.bytes(4, Data())
                    )
            ] {
                #expect(throws: MeetCallWire.WireError.malformedResponse) {
                    if variant == 5 {
                        try MeetAudioStreamWire.confirmRegistration(
                            from: invalid, stream: makeStream(), ssrc: 4242, muted: false, requestID: 9
                        )
                    } else {
                        try MeetAudioStreamWire.confirmMute(
                            from: invalid, stream: makeStream(), muted: true, requestID: 9
                        )
                    }
                }
            }
        }
    }

    @Test func toggleChangesOnlyStreamMuteFlagAndRequestID() throws {
        let stream = try makeStream()
        let header = MeetProto.bytes(1, MeetProto.number(1, 3))
        let mute = try MeetAudioStreamWire.mute(
            stream: stream,
            muted: true,
            requestID: 9,
            requestHeader: header
        )
        let unmute = try MeetAudioStreamWire.mute(
            stream: stream,
            muted: false,
            requestID: 10,
            requestHeader: header
        )
        let operation = try MeetProto.payload(2, mute)
        #expect(try MeetProto.payload(1, operation) == header)
        #expect(try MeetProto.payload(3, operation).isEmpty)
        let sent = try MeetProto.payload(4, operation)
        // Synthetic replica of the owner's modify2/stream4/mute10/flag1 path.
        #expect(sent == identity() + Data([0x52, 0x02, 0x08, 0x01]))
        let unsent = try MeetProto.payload(4, MeetProto.payload(2, unmute))
        #expect(unsent == identity() + Data([0x52, 0x02, 0x08, 0x00]))
        #expect(try MeetProto.value(1, mute) == 9)
        #expect(try MeetProto.value(1, unmute) == 10)
    }

    @Test func confirmsBothMutedAndUnmutedEchoes() throws {
        for muted in [false, true] {
            try MeetAudioStreamWire.confirmMute(
                from: reply(muted: muted), stream: makeStream(), muted: muted, requestID: 9
            )
        }
    }

    @Test func rejectsCrossCallRequestOrStreamOrState() throws {
        let candidates = [
            reply(muted: true, requestID: 10), reply(muted: false),
            reply(muted: true, stream: identity(session: "another")),
            reply(muted: true, stream: identity(conference: "another")),
            reply(muted: true, stream: identity(stream: "another")),
            reply(muted: true, stream: identity(direction: 1)),
            reply(muted: true, stream: identity(kind: 2))
        ]
        for data in candidates {
            #expect(throws: MeetCallWire.WireError.malformedResponse) {
                try MeetAudioStreamWire.confirmMute(
                    from: data,
                    stream: makeStream(),
                    muted: true,
                    requestID: 9
                )
            }
        }
    }

    @Test func rejectsEitherErrorLayerAndAbsentStatus() throws {
        let candidates = [
            reply(muted: true, code: 3), reply(muted: true, legacyStatus: 0),
            reply(muted: true, legacyStatus: 2),
            MeetProto.number(1, 9) + MeetProto.bytes(2, modify(muted: true)),
            reply(muted: true) + MeetProto.bytes(3, Data())
        ]
        for data in candidates {
            #expect(throws: MeetCallWire.WireError.malformedResponse) {
                try MeetAudioStreamWire.confirmMute(
                    from: data,
                    stream: makeStream(),
                    muted: true,
                    requestID: 9
                )
            }
        }
    }

    @Test func rejectsAmbiguousOrMalformedEchoAndBounds() throws {
        let echoed = identity() + MeetProto.bytes(10, MeetProto.number(1, 1))
        let candidates = [
            reply(muted: true) + MeetProto.number(1, 9),
            MeetProto.number(1, 9) + MeetProto.bytes(4, Data()) + MeetProto.bytes(
                2,
                MeetProto.bytes(
                    1,
                    MeetProto.number(1, 1)
                ) + MeetProto.bytes(
                    4,
                    echoed
                )
                    + MeetProto.bytes(
                        4,
                        echoed
                    )
            ),
            reply(muted: true, stream: identity() + MeetProto.number(1, 2)),
            reply(muted: true, stream: identity() + MeetProto.bytes(10, MeetProto.number(1, 1))),
            Data([0x12, 0xFF]), Data(repeating: 0, count: 1_000_001)
        ]
        for data in candidates {
            #expect(throws: MeetCallWire.WireError.malformedResponse) {
                try MeetAudioStreamWire.confirmMute(
                    from: data,
                    stream: makeStream(),
                    muted: true,
                    requestID: 9
                )
            }
        }
    }

    @Test func rejectsMissingIdentityOrHeaderAndInvalidRequestID() throws {
        for value in ["", "line\nbreak", String(repeating: "x", count: 129)] {
            #expect(throws: MeetCallWire.WireError.invalidIdentifier) {
                _ = try MeetAudioStreamWire.Stream(
                    mediaSession: "mediasessions/native",
                    conferenceID: value,
                    streamID: "audio"
                )
            }
        }
        for requestID in [0, UInt64(UInt32.max) + 1] {
            #expect(throws: MeetCallWire.WireError.invalidIdentifier) {
                _ = try MeetAudioStreamWire.mute(
                    stream: makeStream(), muted: true, requestID: requestID, requestHeader: Data([0x08, 0x01])
                )
            }
        }
        for header in [Data(), Data(repeating: 0, count: 10001)] {
            #expect(throws: MeetCallWire.WireError.invalidIdentifier) {
                _ = try MeetAudioStreamWire.mute(
                    stream: makeStream(),
                    muted: true,
                    requestID: 9,
                    requestHeader: header
                )
            }
        }
        #expect(throws: MeetCallWire.WireError.malformedResponse) {
            _ = try MeetAudioStreamWire.mute(
                stream: makeStream(),
                muted: true,
                requestID: 9,
                requestHeader: Data([0x12, 0xFF])
            )
        }
    }

    private func makeStream() throws -> MeetAudioStreamWire.Stream {
        try .init(mediaSession: "mediasessions/native", conferenceID: "conference", streamID: "audio")
    }

    private func identity(
        session: String = "native", conference: String = "conference", stream: String = "audio",
        direction: UInt64 = 2, kind: UInt64 = 1
    ) -> Data {
        MeetProto.number(1, direction) + MeetProto.number(2, kind) + MeetProto.string(3, session)
            + MeetProto.string(4, stream) + MeetProto.string(5, conference)
    }

    private func modify(muted: Bool, legacyStatus: UInt64 = 1, stream: Data? = nil) -> Data {
        MeetProto.bytes(1, MeetProto.number(1, legacyStatus))
            + MeetProto.bytes(
                4,
                (stream ?? identity()) + MeetProto.bytes(10, MeetProto.number(1, muted ? 1 : 0))
            )
    }

    private func reply(
        muted: Bool, requestID: UInt64 = 9, code: UInt64 = 0, legacyStatus: UInt64 = 1, stream: Data? = nil
    ) -> Data {
        MeetProto.number(1, requestID) + MeetProto.bytes(4, code == 0 ? Data() : MeetProto.number(1, code))
            + MeetProto.bytes(2, modify(muted: muted, legacyStatus: legacyStatus, stream: stream))
    }
}
