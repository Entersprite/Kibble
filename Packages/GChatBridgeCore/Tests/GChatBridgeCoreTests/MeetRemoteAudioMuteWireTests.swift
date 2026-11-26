import Foundation
import Testing
@testable import GChatBridgeCore

/// The other person's microphone comes from the DOWN search reply's audio
/// entries (kind 1, field 10.1), alongside the video entries it already carries.
struct MeetRemoteAudioMuteWireTests {
    let context: MeetVideoStreamWire.Context
    let source: MeetVideoSource

    init() throws {
        context = try MeetVideoStreamWire.Context(
            mediaSession: "mediasessions/native",
            conferenceID: "conference"
        )
        source = try MeetVideoSource(primary: 3001, retransmission: 3002)
    }

    @Test func oneRemoteAudioEntryReportsItsMuteFlag() throws {
        #expect(try remoteMuted([audio(mute: 1)]) == true)
        #expect(try remoteMuted([audio(mute: 0)]) == false)
        // An explicit but empty mute message is the protobuf default, not absence.
        let empty = audioIdentity() + MeetProto.bytes(10, Data())
        #expect(try remoteMuted([empty]) == false)
    }

    @Test func anAbsentFlagNoAudioOrSeveralAudioEntriesAreUnknown() throws {
        #expect(try remoteMuted([audioIdentity()]) == nil)
        #expect(try remoteMuted([]) == nil)
        #expect(try remoteMuted([camera(muted: true)]) == nil)
        // Two audio entries cannot be assigned to the one remote person, even
        // when they agree.
        #expect(try remoteMuted([audio(mute: 1), audio(mute: 1, id: "second-audio")]) == nil)
        #expect(try remoteMuted([audio(mute: 0), audio(mute: 1, id: "second-audio")]) == nil)
    }

    @Test func aVideoEntrysMuteNeverStandsInForTheMicrophone() throws {
        // Negative control: the camera is muted, the microphone is not.
        #expect(try remoteMuted([camera(muted: true), audio(mute: 0)]) == false)
        #expect(try remoteMuted([camera(muted: false), audio(mute: 1)]) == true)
    }

    @Test func audioEntriesLeaveVideoSelectionUnchanged() throws {
        let alone = try MeetVideoStreamWire.downstreams(
            from: search([camera(muted: false)]), context: context, requestID: 10
        )
        let mixed = try MeetVideoStreamWire.downstreams(
            from: search([audio(mute: 1), camera(muted: false), audio(mute: 0, id: "second-audio")]),
            context: context, requestID: 10
        )
        #expect(alone.count == 1)
        #expect(mixed == alone)
        #expect(MeetVideoStreamWire.preferred(mixed)?.muted == false)
    }

    @Test func malformedForeignOrMismatchedRepliesAreRejected() throws {
        let valid = search([audio(mute: 1)])
        #expect(throws: (any Error).self) {
            try MeetVideoStreamWire.remoteAudioMuted(from: valid, context: context, requestID: 11)
        }
        let foreign = try MeetVideoStreamWire.Context(
            mediaSession: "mediasessions/other",
            conferenceID: "conference"
        )
        #expect(throws: (any Error).self) {
            try MeetVideoStreamWire.remoteAudioMuted(from: valid, context: foreign, requestID: 10)
        }
        #expect(throws: (any Error).self) { try remoteMuted([audio(mute: 2)]) }
        #expect(throws: (any Error).self) {
            try remoteMuted([MeetProto.number(1, 2) + MeetProto.number(2, 1) + MeetProto.string(
                4,
                "own-audio"
            )])
        }
        let failed = MeetProto.number(1, 10) + MeetProto.bytes(
            3,
            MeetProto.bytes(1, MeetProto.number(1, 1))
                + MeetProto.bytes(2, audio(mute: 1))
        ) + MeetProto.bytes(4, MeetProto.number(1, 7))
        #expect(throws: (any Error).self) {
            try MeetVideoStreamWire.remoteAudioMuted(from: failed, context: context, requestID: 10)
        }
    }

    private func remoteMuted(_ streams: [Data]) throws -> Bool? {
        try MeetVideoStreamWire.remoteAudioMuted(from: search(streams), context: context, requestID: 10)
    }

    private func audioIdentity(id: String = "remote-audio") -> Data {
        MeetProto.number(1, 1) + MeetProto.number(2, 1) + MeetProto.string(3, "native")
            + MeetProto.string(4, id) + MeetProto.string(5, "conference")
    }

    private func audio(mute: UInt64, id: String = "remote-audio") -> Data {
        audioIdentity(id: id) + MeetProto.bytes(10, MeetProto.number(1, mute))
    }

    private func camera(muted: Bool) -> Data {
        context.identity(direction: 1, stream: "remote-camera") + MeetProto.bytes(8, source.protobuf)
            + MeetProto.bytes(10, MeetProto.number(1, muted ? 1 : 0)) + MeetProto.number(11, 1)
    }

    private func search(_ streams: [Data]) -> Data {
        let operation = MeetProto.bytes(1, MeetProto.number(1, 1))
            + streams.reduce(Data()) { $0 + MeetProto.bytes(2, $1) }
        return MeetProto.number(1, 10) + MeetProto.bytes(3, operation) + MeetProto.bytes(
            4,
            MeetProto.number(1, 0)
        )
    }
}
