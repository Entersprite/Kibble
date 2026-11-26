import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
struct NativeMeetActivityTests {
    @Test(arguments: [true, false])
    func recordingCaptionChoiceRequiresItsOwnProviderReadback(echo: Bool) async throws {
        var start = Array(NativeMeetFixture.responses().prefix(4))
        start[3] = NativeMeetFixture.ok(
            NativeMeetFixture.string(1, "spaces/demo/devices/one") + NativeMeetFixture.number(4, 1)
                + NativeMeetFixture.string(31, "fr-FR"),
            token: "30;joined"
        )
        let before = spaceSnapshot(version: 1, recording: nil)
        let active = spaceSnapshot(version: 2, recording: 2, captionLanguage: echo ? "fr-FR" : nil)
        let transport = ScriptedTransport(start + [before, NativeMeetFixture.ok(Data()), active]
            + Array(NativeMeetFixture.responses().suffix(1)))
        let session = try await NativeMeetFixture.session(transport, media: NativeFakeMedia())
        try await session.connect()
        #expect(await session.activities.recordingCaptionLanguages == ["fr-FR"])
        let activity = CallActivity("recording", recordingCaptionLanguage: "fr-FR")
        if echo {
            try await session.performActivity(activity)
        } else {
            await #expect(throws: ChatError.self) { try await session.performActivity(activity) }
        }
        let recording = await session.activities.artifacts.first { $0.kind == "recording" }
        #expect(recording?.phase == "active")
        #expect(recording?.recordingCaptionLanguage == (echo ? "fr-FR" : nil))
        #expect(await transport.sent.filter { $0.url.path.hasSuffix("UpdateMeetingSpace") }.count == 1)
        await session.close()
    }

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

    @Test func aConfirmedRecordingStopRequestsItsAgendaWithoutChangingTheStopResult() async throws {
        let start = Array(NativeMeetFixture.responses().prefix(4))
        let active = spaceSnapshot(version: 1, recording: 2)
        let stopped = spaceSnapshot(version: 2, recording: 3)
        let readyFile = NativeMeetFixture.string(1, "https://drive.google.com/open?id=ready")
            + NativeMeetFixture.number(6, 3) + NativeMeetFixture.number(7, 1)
        let agenda = NativeMeetFixture.ok(NativeMeetFixture.bytes(1, NativeMeetFixture.bytes(19, readyFile)))
        let leave = Array(NativeMeetFixture.responses().suffix(1))
        let transport =
            ScriptedTransport(start + [active, NativeMeetFixture.ok(Data()), stopped, agenda] + leave)
        let session = try await NativeMeetFixture.session(transport, media: NativeFakeMedia())
        try await session.connect()
        try await session.performActivity(CallActivity("recording", enabled: false))
        await session.agendaArtifactRead?.value
        let state = await session.activities
        #expect(state.artifacts.first { $0.kind == "recording" }?.phase == "stopped")
        #expect(state.artifactFiles.map(\.kind) == ["recording"])
        #expect(await transport.sent.suffix(4).map(\.url.lastPathComponent) == [
            "SyncMeetingSpaceCollections", "UpdateMeetingSpace", "SyncMeetingSpaceCollections",
            "FetchCalendarEvent"
        ])
        await session.close()
    }

    @Test func captureReadbackDistinguishesBlockedStartupFailureAndAnOrdinaryStop() async throws {
        let transport = ScriptedTransport(Array(NativeMeetFixture.responses().prefix(1)))
        let session = try await NativeMeetFixture.session(transport, media: NativeFakeMedia())
        let acknowledgement = NativeMeetFixture.bytes(
            5,
            NativeMeetFixture.string(1, "participant")
                + NativeMeetFixture.number(2, 1)
        )
        struct Revision {
            let phase: UInt64
            let state: Data
            let issue: CallArtifactIssue?
        }
        let revisions: [Revision] = [
            .init(phase: 1, state: acknowledgement, issue: .participantCompatibility),
            .init(
                phase: 3,
                state: acknowledgement + NativeMeetFixture.number(2, 2),
                issue: .initializationFailed
            ),
            .init(phase: 3, state: acknowledgement + NativeMeetFixture.number(2, 1), issue: nil),
            .init(phase: 1, state: NativeMeetFixture.bytes(5, NativeMeetFixture.number(2, 1)), issue: nil)
        ]
        for (index, revision) in revisions.enumerated() {
            let response = try spaceSnapshot(
                version: UInt64(index + 1), recording: revision.phase, stateData: revision.state
            ).get()
            let snapshot = try MeetActivityCollections.decode(response.body, space: "spaces/demo")
            await session.reconcileActivities(snapshot)
            let recording = await session.activities.artifacts.first { $0.kind == "recording" }
            #expect(recording?.issue == revision.issue?.rawValue)
            #expect(recording?.canSetEnabled(revision.phase == 3) == true)
        }
    }

    @Test func meetingLocksDisableChatAndReactionsAndOlderMetadataCannotReenableThem() async throws {
        let transport = ScriptedTransport(Array(NativeMeetFixture.responses().prefix(1)))
        let session = try await NativeMeetFixture.session(transport, media: NativeFakeMedia())
        let received = ActivityUpdates()
        await session.setActivitiesHandler { await received.append($0) }
        #expect(await received.states.first?.availableActions.contains("chat") == true)

        let message = NativeMeetFixture.string(1, "message-one")
            + NativeMeetFixture.bytes(5, NativeMeetFixture.string(1, "Last message"))
            + NativeMeetFixture.number(6, 1)
        let locked = NativeMeetFixture.number(2, 1) + NativeMeetFixture.number(9, 1)
        try await session.reconcileActivities(chatSnapshot(version: 9, settings: locked, message: message))
        let states = await received.states
        #expect(states.count == 2)
        #expect(states.last?.messages.map(\.text) == ["Last message"])
        #expect(states.last?.availableActions.contains("chat") == false)
        #expect(states.last?.availableActions.contains("react") == false)

        try await session.reconcileActivities(chatSnapshot(version: 8, settings: Data()))
        try await session.reconcileActivities(MeetActivityCollections.decode(Data(), space: "spaces/demo"))
        #expect(await !session.activities.availableActions.contains("chat"))
        #expect(await !session.activities.availableActions.contains("react"))
        await #expect(throws: ChatError.self) { try await session.applyActivity(CallActivity(
            "chat",
            text: "blocked"
        )) }
        let unrelated = NativeMeetFixture.number(8, 1)
        try await session.reconcileActivities(chatSnapshot(version: 10, settings: unrelated))
        #expect(await session.activities.availableActions.contains("chat"))
        #expect(await session.activities.availableActions.contains("react"))
        await session.close()
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

    private func spaceSnapshot(
        version: UInt64, recording: UInt64?, captionLanguage: String? = nil, stateData: Data = Data()
    )
        -> Result<HTTPResponse, any Error> {
        let languages = captionLanguage
            .map { NativeMeetFixture.bytes(6, NativeMeetFixture.string(1, $0)) } ?? Data()
        let flag = captionLanguage == nil ? Data() : NativeMeetFixture.number(4, 1)
        let call = recording.map { NativeMeetFixture.bytes(
            20,
            NativeMeetFixture.string(1, "recording-session") + NativeMeetFixture.bytes(
                2,
                NativeMeetFixture.number(1, $0) + languages + stateData
            ) + flag
        ) } ?? Data()
        let space = NativeMeetFixture.string(1, "spaces/demo") + NativeMeetFixture.bytes(6, call)
        let full = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, version)) + NativeMeetFixture.bytes(
            2,
            space
        )
        return NativeMeetFixture.ok(NativeMeetFixture.bytes(1, NativeMeetFixture.bytes(2, full)))
    }

    private func chatSnapshot(version: UInt64, settings: Data, message: Data? = nil) throws
        -> MeetActivityCollections.Snapshot {
        let metadata = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, version))
        let space = NativeMeetFixture.string(1, "spaces/demo")
            + NativeMeetFixture.bytes(6, NativeMeetFixture.bytes(11, settings))
        let full = NativeMeetFixture.bytes(
            1,
            NativeMeetFixture.bytes(2, metadata + NativeMeetFixture.bytes(2, space))
        )
        let messages = message.map {
            NativeMeetFixture.bytes(3, NativeMeetFixture.bytes(2, metadata + NativeMeetFixture.bytes(2, $0)))
        } ?? Data()
        return try MeetActivityCollections.decode(
            Data((full + messages).base64EncodedString().utf8),
            space: "spaces/demo"
        )
    }
}

private actor ActivityUpdates {
    private(set) var states: [CallActivitiesState] = []

    func append(_ state: CallActivitiesState) {
        states.append(state)
    }
}
