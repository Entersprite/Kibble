import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetVideoStreamWireTests {
    let context: MeetVideoStreamWire.Context
    let source: MeetVideoSource

    init() throws {
        context = try MeetVideoStreamWire.Context(
            mediaSession: "mediasessions/native",
            conferenceID: "conference"
        )
        source = try MeetVideoSource(primary: 3001, retransmission: 3002)
    }

    let header = MeetProto.string(1, "current")

    @Test func registrationCarriesCurrentSourcesAndStartsMuted() throws {
        let request = try MeetVideoStreamWire.register(
            context: context,
            source: source,
            requestID: 10,
            header: header
        )
        let operation = try MeetProto.payload(4, request), stream = try MeetProto.payload(4, operation)
        #expect(try MeetProto.value(1, request) == 10)
        #expect(try MeetProto.value(1, stream) == 2)
        #expect(try MeetProto.value(2, stream) == 2)
        #expect(try MeetProto.text(3, stream) == "native")
        #expect(try MeetProto.text(4, stream) == "video")
        #expect(try MeetVideoSource.parse(MeetProto.payload(8, stream)) == source)
        #expect(try MeetProto.value(1, MeetProto.payload(10, stream)) == 1)
        try MeetVideoStreamWire.confirm(
            from: reply(variant: 5, stream: stream),
            context: context,
            source: source,
            muted: true,
            requestID: 10
        )
        let mute = try MeetVideoStreamWire.mute(context: context, muted: false, requestID: 10, header: header)
        let unmuted = try MeetProto.payload(4, MeetProto.payload(2, mute))
        #expect(try MeetProto.value(1, MeetProto.payload(10, unmuted)) == 0)
        try MeetVideoStreamWire.confirm(
            from: reply(variant: 2, stream: unmuted),
            context: context,
            muted: false,
            requestID: 10
        )
    }

    @Test func searchAndViewKeepTheDownstreamIdentityAndSourcePair() throws {
        let request = try MeetVideoStreamWire.search(context: context, requestID: 10, header: header)
        #expect(try MeetProto.value(2, MeetProto.payload(3, request)) == 1)
        let streams = try MeetVideoStreamWire.downstreams(
            from: reply(variant: 3, stream: downstream, field: 2),
            context: context,
            requestID: 10
        )
        #expect(streams.count == 1)
        let stream = try #require(streams.first)
        #expect(stream.source == source)
        #expect(stream.muted)
        let view = try MeetVideoStreamWire.view(
            context: context,
            stream: stream,
            requestID: 10,
            header: header
        )
        let value = try MeetProto.payload(4, MeetProto.payload(2, view))
        #expect(try MeetProto.value(1, value) == 1)
        #expect(try MeetProto.text(4, value) == "remote-camera")
        #expect(try MeetVideoSource.parse(MeetProto.payload(8, value)) == source)
        let dimensions = try MeetProto.payload(3, MeetProto.payload(9, value))
        #expect(try MeetProto.value(1, dimensions) == 720)
        #expect(try MeetProto.value(2, dimensions) == 1280)
        try MeetVideoStreamWire.confirmView(
            from: reply(variant: 2, stream: downstream),
            context: context,
            stream: stream,
            requestID: 10
        )
    }

    @Test func participantKeysAreScopedDeviceResourcesAndStoppingAViewIsExplicit() throws {
        let addressed = downstream + MeetProto.string(6, "spaces/demo/devices/peer")
        let streams = try MeetVideoStreamWire.downstreams(
            from: reply(variant: 3, stream: addressed, field: 2), context: context, requestID: 10
        )
        let stream = try #require(streams.first)
        #expect(stream.deviceName == "spaces/demo/devices/peer")
        let stop = try MeetVideoStreamWire.view(
            context: context, stream: stream, requestID: 10, header: header, enabled: false
        )
        let value = try MeetProto.payload(4, MeetProto.payload(2, stop))
        let selection = try MeetProto.payload(9, value)
        #expect(try MeetProto.value(2, selection) == 0)
        #expect(try MeetProto.text(6, value) == "spaces/demo/devices/peer")
        let audio = MeetProto.number(1, 1) + MeetProto.number(2, 1) + MeetProto.string(4, "audio")
            + MeetProto.string(6, "spaces/demo/devices/peer") + MeetProto.bytes(10, MeetProto.number(1, 1))
        let people = try MeetVideoStreamWire.deviceAudio(
            from: reply(variant: 3, stream: audio, field: 2), context: context, requestID: 10
        )
        #expect(people.count == 1)
        #expect(people.first?.deviceName == stream.deviceName)
        #expect(people.first?.muted == true)
    }

    @Test func repliesRejectForeignScopesWrongRequestsAndFailureStatuses() throws {
        let valid = reply(variant: 3, stream: downstream, field: 2)
        let foreign = try MeetVideoStreamWire.Context(
            mediaSession: "mediasessions/other",
            conferenceID: "conference"
        )
        #expect(throws: (any Error).self) { try MeetVideoStreamWire.downstreams(
            from: valid,
            context: foreign,
            requestID: 10
        ) }
        #expect(throws: (any Error).self) { try MeetVideoStreamWire.downstreams(
            from: valid,
            context: context,
            requestID: 11
        ) }
        #expect(throws: (any Error).self) { try MeetVideoStreamWire.downstreams(
            from: valid + Data([0x80]),
            context: context,
            requestID: 10
        ) }
        #expect(throws: (any Error).self) { try MeetVideoStreamWire.downstreams(
            from: reply(variant: 2, stream: downstream),
            context: context,
            requestID: 10
        ) }
        #expect(throws: (any Error).self) { try MeetVideoStreamWire.downstreams(
            from: reply(variant: 3, stream: downstream, field: 2, status: 7),
            context: context,
            requestID: 10
        ) }
        let duplicated = downstream + MeetProto.string(3, "native")
        #expect(throws: (any Error).self) { try MeetVideoStreamWire.downstreams(
            from: reply(variant: 3, stream: duplicated, field: 2),
            context: context,
            requestID: 10
        ) }
    }

    @Test func absentParentsInheritOnlyTheCurrentCollectionAndAudioIsNotVideo() throws {
        let inherited = MeetProto.number(1, 1) + MeetProto.number(2, 2) + MeetProto.string(4, "remote-camera")
            + MeetProto.bytes(8, source.protobuf) + MeetProto.number(11, 1)
        let streams = try MeetVideoStreamWire.downstreams(
            from: reply(variant: 3, stream: inherited, field: 2),
            context: context,
            requestID: 10
        )
        #expect(streams.first?.muted == false)
        let audio = MeetProto.number(1, 1) + MeetProto.number(2, 1) + MeetProto.string(4, "remote-audio")
        let ignored = try MeetVideoStreamWire.downstreams(
            from: reply(variant: 3, stream: audio, field: 2),
            context: context,
            requestID: 10
        )
        #expect(ignored.isEmpty)
    }

    @Test func malformedOrSimulcastSourcesAreNotBoundToASingleReceiver() throws {
        for value in [
            Data([0x08, 0]),
            Data([0x0A, 1, 0x80]),
            source.protobuf + MeetProto.number(1, 4001),
            MeetProto.bytes(1, MeetProto.unsigned(UInt64(UInt32.max) + 1))
        ] {
            #expect(throws: (any Error).self) { try MeetVideoSource.parse(value) }
        }
    }

    @Test func presentationRegistrationAndRepeatedRemoteSwitchKeepScopedSources() throws {
        let registration = try MeetVideoStreamWire.register(
            context: context,
            source: source,
            camera: false,
            requestID: 10,
            header: header
        )
        let stream = try MeetProto.payload(4, MeetProto.payload(4, registration))
        #expect(try MeetProto.value(11, stream) == 0)
        try MeetVideoStreamWire.confirm(
            from: reply(variant: 5, stream: stream),
            context: context,
            source: source,
            muted: true,
            camera: false,
            requestID: 10
        )
        #expect(throws: (any Error).self) {
            try MeetVideoStreamWire.confirm(
                from: reply(variant: 5, stream: stream),
                context: context,
                source: source,
                muted: true,
                camera: true,
                requestID: 10
            )
        }
        let common = context.identity(direction: 1, stream: "remote-video") + MeetProto.bytes(
            8,
            source.protobuf
        )
        for camera in [false, true, false, true] {
            let value = common + MeetProto.number(11, camera ? 1 : 0)
                + MeetProto.bytes(10, MeetProto.number(1, camera ? 1 : 0))
            let streams = try MeetVideoStreamWire.downstreams(
                from: reply(variant: 3, stream: value, field: 2),
                context: context,
                requestID: 10
            )
            let selected = try #require(MeetVideoStreamWire.preferred(streams))
            #expect(selected.source == source)
            #expect(selected.isCamera == camera)
            #expect(selected.muted == camera)
        }
    }

    @Test func presentationPriorityAndAmbiguityDoNotChooseAnArbitraryParticipant() throws {
        let presentation = try context.identity(direction: 1, stream: "presentation")
            + MeetProto.bytes(8, MeetVideoSource(primary: 4001, retransmission: 4002).protobuf)
            + MeetProto.number(11, 0)
        let mixed = reply(variant: 3, stream: downstream, field: 2)
        let operation = try MeetProto.payload(3, mixed) + MeetProto.bytes(2, presentation)
        let response = MeetProto.number(1, 10) + MeetProto.bytes(3, operation) + MeetProto.bytes(4, Data())
        let streams = try MeetVideoStreamWire.downstreams(from: response, context: context, requestID: 10)
        #expect(streams.count == 2)
        #expect(MeetVideoStreamWire.preferred(streams)?.isCamera == false)
        #expect(MeetVideoStreamWire.preferred(streams + [streams[1]]) == nil)
    }

    var downstream: Data {
        context.identity(direction: 1, stream: "remote-camera") + MeetProto.bytes(8, source.protobuf)
            + MeetProto.bytes(10, MeetProto.number(1, 1)) + MeetProto.number(11, 1)
    }

    func reply(variant: UInt64, stream: Data, field: UInt64 = 4, status: UInt64 = 0) -> Data {
        let operation = MeetProto.bytes(1, MeetProto.number(1, 1)) + MeetProto.bytes(field, stream)
        return MeetProto.number(1, 10) + MeetProto.bytes(variant, operation) + MeetProto.bytes(
            4,
            MeetProto.number(1, status)
        )
    }
}
