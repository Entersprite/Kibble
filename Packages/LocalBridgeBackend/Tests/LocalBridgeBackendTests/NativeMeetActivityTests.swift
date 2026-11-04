import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
struct NativeMeetActivityTests {
    @Test func recordingIsReadBackAndARefusalDoesNotEndTheAudioCallOrReplayTheWrite() async throws {
        let start = Array(NativeMeetFixture.responses().prefix(4))
        let before = spaceSnapshot(version: 1, recording: nil)
        let active = spaceSnapshot(version: 2, recording: 2)
        let transport = ScriptedTransport(start + [before, NativeMeetFixture.ok(Data()), active]
            + Array(NativeMeetFixture.responses().suffix(1)))
        let media = NativeFakeMedia()
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        try await session.performActivity(CallActivity("recording"))
        #expect(await session.activities.artifacts.first { $0.kind == "recording" }?.phase == "active")
        #expect(media.isConnected)
        let requests = await transport.sent
        #expect(requests.suffix(3).map(\.url.lastPathComponent) == [
            "SyncMeetingSpaceCollections", "UpdateMeetingSpace", "SyncMeetingSpaceCollections"
        ])
        await session.close()
        let refused = HTTPResponse(status: 403, headers: HTTPHeaders([]), body: Data())
        let deniedTransport = ScriptedTransport(start + [before, .success(refused)]
            + Array(NativeMeetFixture.responses().suffix(1)))
        let deniedMedia = NativeFakeMedia()
        let deniedSession = try await NativeMeetFixture.session(deniedTransport, media: deniedMedia)
        try await deniedSession.connect()
        await #expect(throws: MeetCallClientError.self) {
            try await deniedSession.performActivity(CallActivity("recording"))
        }
        #expect(deniedMedia.isConnected)
        #expect(await deniedTransport.sent.count == 6)
        #expect(await deniedSession.activities.artifacts.first { $0.kind == "recording" }?.phase == "stopped")
        await deniedSession.close()
    }

    @Test func oldOrMissingCollectionsCannotRewindConfirmedActivityAndUnconfirmedWritesStayUncertain(
    ) async throws {
        let transport = ScriptedTransport(Array(NativeMeetFixture.responses().prefix(1)))
        let session = try await NativeMeetFixture.session(transport, media: NativeFakeMedia())
        let active = try MeetActivityCollections.decode(
            #require(spaceSnapshot(version: 8, recording: 2).get().body),
            space: "spaces/demo"
        )
        let old = try MeetActivityCollections.decode(
            #require(spaceSnapshot(version: 7, recording: nil).get().body),
            space: "spaces/demo"
        )
        await session.reconcileActivities(active)
        await session.reconcileActivities(old)
        try await session.reconcileActivities(MeetActivityCollections.decode(Data(), space: "spaces/demo"))
        #expect(await session.activities.artifacts.first { $0.kind == "recording" }?.phase == "active")
        await #expect(throws: ChatError.self) { try await session.confirmActivity(
            CallActivity("recording", enabled: false),
            baseline: []
        ) }
        await #expect(throws: ChatError.self) { try await session.activityResource(UUID(), kind: "poll") }
    }

    @Test func assignmentsSurviveRoomOnlyUpdatesWithoutTreatingCurrentLocationAsAssignment() async throws {
        let transport = ScriptedTransport(Array(NativeMeetFixture.responses().prefix(1)))
        let session = try await NativeMeetFixture.session(transport, media: NativeFakeMedia())
        let name = "spaces/demo/rooms/one", person = "spaces/demo/people/taylor"
        let room = NativeMeetFixture.string(1, name) + NativeMeetFixture.string(3, "One")
        let breakout = NativeMeetFixture.number(2, 1) + NativeMeetFixture.bytes(4, room)
        let currentOnly = NativeMeetFixture.string(1, person) + NativeMeetFixture.string(4, name)
        await session.reconcileRooms(breakout)
        await session.reconcileRoomPeople([currentOnly])
        #expect(await session.activities.rooms.first?.participants.isEmpty == true)
        await session.reconcileRoomPeople([currentOnly + NativeMeetFixture.string(5, name)])
        let assigned = await session.activities.rooms.first?.participants
        #expect(assigned?.count == 1)
        await session.reconcileRooms(breakout)
        #expect(await session.activities.rooms.first?.participants == assigned)
        let handle = try #require(await session.activities.people.first?.id)
        await session.reconcileRoomPeople([])
        await #expect(throws: ChatError.self) { try await session.activityResource(handle, kind: "person") }
    }

    @Test func meetingLocksDisableChatAndReactionsAndOlderMetadataCannotReenableThem() async throws {
        let transport = ScriptedTransport(Array(NativeMeetFixture.responses().prefix(1)))
        let session = try await NativeMeetFixture.session(transport, media: NativeFakeMedia())
        let settings = NativeMeetFixture.number(8, 1) + NativeMeetFixture.number(9, 1)
        let space = NativeMeetFixture.string(1, "spaces/demo")
            + NativeMeetFixture.bytes(6, NativeMeetFixture.bytes(11, settings))
        let full = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, 9)) + NativeMeetFixture.bytes(
            2,
            space
        )
        let locked = try MeetActivityCollections.decode(
            Data(NativeMeetFixture.bytes(1, NativeMeetFixture.bytes(2, full)).base64EncodedString().utf8),
            space: "spaces/demo"
        )
        await session.reconcileActivities(locked)
        try await session.reconcileActivities(MeetActivityCollections.decode(Data(), space: "spaces/demo"))
        #expect(await !session.activities.availableActions.contains("chat"))
        #expect(await !session.activities.availableActions.contains("react"))
        await #expect(throws: ChatError.self) { try await session.applyActivity(CallActivity(
            "chat",
            text: "blocked"
        )) }
    }

    @Test func answeredQuestionsRemainVisibleAndAnonymousQuestionsRequireTheSeriesSetting() async throws {
        let transport = ScriptedTransport(Array(NativeMeetFixture.responses().prefix(1)))
        let session = try await NativeMeetFixture.session(transport, media: NativeFakeMedia())
        let parent = "spaces/demo/questionSeries/one"
        let series = NativeMeetFixture.string(1, parent) + NativeMeetFixture.number(2, 1)
        let question = NativeMeetFixture.string(1, parent + "/questions/one")
            + NativeMeetFixture.string(4, "Why?") + NativeMeetFixture.number(6, 1)
            + NativeMeetFixture.number(7, 2)
        func collection(_ field: UInt64, _ value: Data) -> Data {
            let full = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, 1))
                + NativeMeetFixture.bytes(2, value)
            return NativeMeetFixture.bytes(field, NativeMeetFixture.bytes(2, full))
        }
        let body = Data((collection(7, series) + collection(6, question)).base64EncodedString().utf8)
        try await session.reconcileActivities(MeetActivityCollections.decode(body, space: "spaces/demo"))
        #expect(await session.activities.questions.first?.isAnswered == true)
        #expect(await session.activities.allowsAnonymousQuestions == false)
        await #expect(throws: ChatError.self) {
            try await session.activityRequest(
                CallActivity("askQuestion", text: "Why?", enabled: false),
                space: "spaces/demo",
                sequence: 1
            )
        }
    }

    private func spaceSnapshot(version: UInt64, recording: UInt64?) -> Result<HTTPResponse, any Error> {
        let call = recording.map { NativeMeetFixture.bytes(
            20,
            NativeMeetFixture.string(1, "recording-session") + NativeMeetFixture.bytes(
                2,
                NativeMeetFixture.number(1, $0)
            )
        ) } ?? Data()
        let space = NativeMeetFixture.string(1, "spaces/demo") + NativeMeetFixture.bytes(6, call)
        let full = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, version)) + NativeMeetFixture.bytes(
            2,
            space
        )
        return NativeMeetFixture.ok(NativeMeetFixture.bytes(1, NativeMeetFixture.bytes(2, full)))
    }
}
