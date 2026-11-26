import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService
@testable import ServiceClient

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CallActivityControlTests {
    @Test func activitiesCrossSerializationAndKeepCallOwnershipAndMutationIdentity() async throws {
        let harness = try await CallHarness.make(), account = harness.accounts[0]
        let initial = try await harness.read(account)
        let source = try #require(initial.sourceID), call = UUID()
        _ = try await harness.client().call(
            JoinMeetingCall(
                url: #require(URL(string: "https://meet.example.test/room")),
                callID: call,
                sourceID: source
            ),
            account: account.id,
            revision: account.currentRevision
        )
        try await callEventually { try await harness.read(account).meetingCall?.phase == .connected }
        let create = PerformCallActivity(
            callID: call,
            sourceID: source,
            activity: CallActivity(
                "createPoll",
                text: "Choose",
                options: ["One", "Two"]
            )
        )
        _ = try await harness.client().call(create, account: account.id, revision: account.currentRevision)
        await #expect(throws: ServiceFailure.operationConflict) {
            try await harness.client().call(create, account: account.id, revision: account.currentRevision)
        }
        try await callEventually { try await harness.read(account).interaction?.activities?.polls.count == 1 }
        let poll = try #require(try await harness.read(account).interaction?.activities?.polls.first)
        for activity in followupActivities(poll: poll.id) {
            _ = try await harness.client().call(
                PerformCallActivity(callID: call, sourceID: source, activity: activity),
                account: account.id,
                revision: account.currentRevision
            )
        }
        try await callEventually {
            try await harness.read(account).interaction?.activities?.rooms.first?.isOpen == true
        }
        try await verifyAddressedWrites(harness, account: account, call: call, source: source)
        try await verifyCohostChanges(harness, account: account, call: call, source: source)
        try await verifyParticipantModeration(harness, account: account, call: call, source: source)
        try await verifyWaitingControls(harness, account: account, call: call, source: source)
        try await verifyMeetingChat(harness, account: account, call: call)
        try await verifyProjection(harness, account: account, call: call)
        await verifyRejections(harness, account: account, call: call, source: source)
        try await verifyConferenceEnd(harness, account: account, call: call, source: source)
        await harness.service.shutdown()
    }

    private func verifyWaitingControls(
        _ harness: CallHarness,
        account: AccountRecord,
        call: UUID,
        source: UUID
    )
        async throws {
        let fixture = try #require(await harness.providers.source(account.id, device: .init("one")))
        let waiting = [
            CallWaitingParticipant(id: UUID(), name: "Avery", canDeny: true, warning: .suspiciousUser),
            CallWaitingParticipant(id: UUID(), name: "Robin", canDeny: true),
            CallWaitingParticipant(id: UUID(), name: "Jules", canDeny: false),
            CallWaitingParticipant(id: UUID(), name: "Sam", canDeny: false, isJoinRequest: true)
        ]
        fixture.setWaitingParticipants(waiting, callID: call)
        let moving = CallParticipantDevice(
            id: UUID(), displayName: "Taylor", role: .participant, canSendToWaitingRoom: true
        )
        let remaining = CallParticipantDevice(id: UUID(), displayName: "Maya")
        let originalRoster = [remaining, moving]
        fixture.setParticipantDevices(originalRoster, callID: call)
        try await callEventually {
            let state = try await harness.read(account)
            return state.interaction?.activities?.waitingParticipants == waiting && state
                .participants == originalRoster
        }
        _ = try await harness.client().call(PerformCallActivity(
            callID: call, sourceID: source,
            activity: CallActivity("sendParticipantToWaitingRoom", resourceID: moving.id)
        ), account: account.id, revision: account.currentRevision)
        let namesAfterMove = waiting.map(\.name) + ["Taylor"]
        try await callEventually {
            let state = try await harness.read(account)
            return state.participants == [remaining]
                && state.interaction?.activities?.waitingParticipants.map(\.name) == namesAfterMove
        }
        let moved = try #require(try await harness.read(account).interaction?.activities?.waitingParticipants
            .last)
        #expect(moved.id != moving.id && !moved.canDeny)
        var deny = CallActivity("respondToAdmissions", enabled: false)
        deny.participantIDs = Array(waiting.prefix(2)).map(\.id)
        for activity in [
            deny, CallActivity("respondToAdmission", resourceID: waiting[2].id),
            CallActivity("respondToAdmission", resourceID: moved.id),
            CallActivity("respondToAdmission", resourceID: waiting[3].id)
        ] {
            _ = try await harness.client().call(
                PerformCallActivity(callID: call, sourceID: source, activity: activity),
                account: account.id, revision: account.currentRevision
            )
        }
        try await callEventually {
            let state = try await harness.read(account)
            return state.interaction?.activities?.waitingParticipants.isEmpty == true
                && state.participants?.map(\.displayName) == ["Maya", "Jules", "Taylor", "Sam"]
        }
    }

    private func verifyParticipantModeration(
        _ harness: CallHarness,
        account: AccountRecord,
        call: UUID,
        source: UUID
    )
        async throws {
        let fixture = try #require(await harness.providers.source(account.id, device: .init("one")))
        let target = CallParticipantDevice(
            id: UUID(), displayName: "Taylor", microphoneMuted: false, isPinnedForEveryone: false
        )
        let other = CallParticipantDevice(
            id: UUID(), displayName: "Maya", microphoneMuted: false, canBlockInMeeting: true
        )
        fixture.setParticipantDevices([target, other], callID: call)
        try await callEventually { try await harness.read(account).participants == [target, other] }
        _ = try await harness.client().call(PerformCallActivity(
            callID: call, sourceID: source, activity: CallActivity("setPinForEveryone", resourceID: target.id)
        ), account: account.id, revision: account.currentRevision)
        try await callEventually {
            try await harness.read(account).participants?.first?.isPinnedForEveryone == true
        }
        _ = try await harness.client().call(PerformCallActivity(
            callID: call, sourceID: source, activity: CallActivity("muteParticipant", resourceID: target.id)
        ), account: account.id, revision: account.currentRevision)
        try await callEventually { try await harness.read(account).participants?.map(\.microphoneMuted) == [
            true,
            false
        ] }
        _ = try await harness.client().call(PerformCallActivity(
            callID: call, sourceID: source, activity: CallActivity("muteAllParticipants")
        ), account: account.id, revision: account.currentRevision)
        try await callEventually { try await harness.read(account).participants?.map(\.microphoneMuted) == [
            true,
            true
        ] }
        #expect(try await harness.read(account).meetingCall?.isMuted == false)
        _ = try await harness.client().call(PerformCallActivity(
            callID: call, sourceID: source, activity: CallActivity("removeParticipant", resourceID: target.id)
        ), account: account.id, revision: account.currentRevision)
        try await callEventually { try await harness.read(account).participants?.map(\.id) == [other.id] }
        _ = try await harness.client().call(PerformCallActivity(
            callID: call, sourceID: source, activity: CallActivity("blockParticipant", resourceID: other.id)
        ), account: account.id, revision: account.currentRevision)
        try await callEventually { try await harness.read(account).participants?.isEmpty == true }
        #expect(try await harness.read(account).meetingCall?.phase == .connected)
    }

    private func verifyCohostChanges(_ harness: CallHarness, account: AccountRecord, call: UUID, source: UUID)
        async throws {
        let fixture = try #require(await harness.providers.source(account.id, device: .init("one")))
        let target = CallParticipantDevice(id: UUID(), displayName: "Taylor", role: .participant)
        fixture.setParticipantDevices([target], callID: call)
        try await callEventually { try await harness.read(account).participants == [target] }
        for enabled in [true, false] {
            _ = try await harness.client().call(PerformCallActivity(
                callID: call, sourceID: source,
                activity: CallActivity("setCohost", resourceID: target.id, enabled: enabled)
            ), account: account.id, revision: account.currentRevision)
            var expected = target
            expected.role = enabled ? .cohost : .participant
            try await callEventually { try await harness.read(account).participants == [expected] }
        }
    }

    private func verifyConferenceEnd(_ harness: CallHarness, account: AccountRecord, call: UUID, source: UUID)
        async throws {
        _ = try await harness.client().call(
            PerformCallActivity(callID: call, sourceID: source, activity: CallActivity("endConference")),
            account: account.id,
            revision: account.currentRevision
        )
        try await callEventually {
            let state = try await harness.read(account)
            return state.meetingCall?.phase == .ended && state.interaction == nil
        }
    }

    private func followupActivities(poll: UUID) -> [CallActivity] {
        [
            CallActivity("votePoll", resourceID: poll, selections: [1]),
            CallActivity("closePoll", resourceID: poll),
            CallActivity("sharePollResults", resourceID: poll),
            CallActivity("chat", text: "hello"),
            CallActivity("react", text: "👍"),
            CallActivity("captions", options: ["en-US", "hu-HU"]),
            CallActivity("recording", recordingCaptionLanguage: "fr-FR"),
            CallActivity("transcription"),
            CallActivity("notes"),
            CallActivity("attendance"),
            CallActivity("hostManagement"),
            CallActivity("allowChatMessages", enabled: false),
            CallActivity("allowScreenSharing", enabled: false),
            CallActivity("allowMicrophone", enabled: false),
            CallActivity("allowCamera", enabled: false),
            CallActivity("allowJoiningBeforeHost", enabled: false),
            CallActivity("setMeetingAccess", options: ["restricted"]),
            CallActivity("allowJoinRequests", enabled: false),
            CallActivity("allowReactions", enabled: false),
            CallActivity(
                "askQuestion",
                text: "Why?"
            ),
            CallActivity("createRooms", options: ["One", "Two"]),
            CallActivity("openRooms")
        ]
    }

    private func verifyAddressedWrites(
        _ harness: CallHarness, account: AccountRecord, call: UUID, source: UUID
    ) async throws {
        let activities = try #require(try await harness.read(account).interaction?.activities)
        let question = try #require(activities.questions.first), room = try #require(activities.rooms.first)
        let person = try #require(activities.people.first)
        let message = try #require(activities.messages.first)
        var assignment = CallActivity("assignRoom", resourceID: room.id)
        assignment.participantIDs = [person.id]
        for activity in [
            CallActivity("voteQuestion", resourceID: question.id),
            CallActivity("answerQuestion", resourceID: question.id),
            CallActivity("setMeetingMessagePin", resourceID: message.id),
            assignment
        ] {
            _ = try await harness.client().call(
                PerformCallActivity(callID: call, sourceID: source, activity: activity),
                account: account.id, revision: account.currentRevision
            )
        }
        try await callEventually {
            let state = try await harness.read(account).interaction?.activities
            return state?.questions.first?.isAnswered == true && state?.questions.first?.votes == 1
                && state?.rooms.first?.participants == [person.id]
                && state?.messages.first?.isPinned == true
        }
    }

    private func verifyProjection(_ harness: CallHarness, account: AccountRecord, call: UUID) async throws {
        let state = try await harness.read(account), activities = try #require(state.interaction?.activities)
        #expect(state.meetingCall?.id == call && state.meetingCall?.phase == .connected)
        #expect(activities.artifacts.first { $0.kind == "recording" }?.recordingCaptionLanguage == "fr-FR")
        #expect(activities.polls.first?.selections == [1] && activities.polls.first?.isOpen == false)
        #expect(activities.messages.first?.text == "hello")
        #expect(activities.reactions.first?.emoji == "👍")
        #expect(activities.captionLanguages?.translations["en-US"] == ["fr-FR", "hu-HU"])
        #expect(activities.captions?.displayLanguage == "hu-HU" && activities.captions?.segments.count == 1)
        #expect(activities.artifacts.allSatisfy { $0.phase == "active" })
        #expect(activities.attendanceReportEnabled == true)
        #expect(activities.hostSettings == CallHostSettings(
            managementEnabled: true, reactionsAllowed: false, chatMessagesAllowed: false,
            screenSharingAllowed: false, microphoneAllowed: false, cameraAllowed: false,
            joiningBeforeHostAllowed: false, waitingRoomEnabled: false,
            meetingAccess: CallMeetingAccess(
                preset: "restricted",
                availablePresets: ["open", "trusted", "restricted"],
                joinRequestsAllowed: false
            )
        ))
        #expect(!activities.availableActions.contains("react"))
        #expect(activities.questions.first?.text == "Why?")
    }

    private func verifyRejections(
        _ harness: CallHarness,
        account: AccountRecord,
        call: UUID,
        source: UUID
    ) async {
        await #expect(throws: ServiceFailure.notAuthorized) {
            try await harness.client(session: "intruder").call(
                PerformCallActivity(
                    callID: call,
                    sourceID: source,
                    activity: CallActivity(
                        "notes",
                        enabled: false
                    )
                ),
                account: account.id,
                revision: account.currentRevision
            )
        }
        await #expect(throws: ServiceFailure.staleCallSource) {
            try await harness.client().call(PerformCallActivity(
                callID: call,
                sourceID: UUID(),
                activity: CallActivity("chat", text: "wrong source")
            ), account: account.id, revision: account.currentRevision)
        }
        await #expect(throws: ServiceFailure.unsupportedOperation) {
            try await harness.client().call(
                PerformCallActivity(
                    callID: call,
                    sourceID: source,
                    activity: CallActivity("futureMutation")
                ),
                account: account.id,
                revision: account.currentRevision
            )
        }
    }
}

private extension CallActivityControlTests {
    func verifyMeetingChat(_ harness: CallHarness, account: AccountRecord, call: UUID) async throws {
        let fixture = try #require(await harness.providers.source(account.id, device: .init("one")))
        let route = CallMeetingChat(conversationID: .init("space/meeting"), canSend: false)
        fixture.setMeetingChat(route, callID: call)
        try await callEventually {
            try await harness.read(account).interaction?.activities?.meetingChat == route
        }
        #expect(try await harness.read(account).meetingCall?.target.conversationID == nil)
        fixture.setMeetingChat(nil, callID: call)
        try await callEventually {
            try await harness.read(account).interaction?.activities?.meetingChat == nil
        }
    }
}
