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
        try await verifyProjection(harness, account: account, call: call)
        await verifyRejections(harness, account: account, call: call, source: source)
        await harness.service.shutdown()
    }

    private func followupActivities(poll: UUID) -> [CallActivity] {
        [
            CallActivity("votePoll", resourceID: poll, selections: [1]),
            CallActivity("closePoll", resourceID: poll),
            CallActivity("sharePollResults", resourceID: poll),
            CallActivity("chat", text: "hello"),
            CallActivity("react", text: "👍"),
            CallActivity("recording"),
            CallActivity("transcription"),
            CallActivity("notes"),
            CallActivity("attendance"),
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
        var assignment = CallActivity("assignRoom", resourceID: room.id)
        assignment.participantIDs = [person.id]
        for activity in [
            CallActivity("voteQuestion", resourceID: question.id),
            CallActivity("answerQuestion", resourceID: question.id),
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
        }
    }

    private func verifyProjection(_ harness: CallHarness, account: AccountRecord, call: UUID) async throws {
        let state = try await harness.read(account), activities = try #require(state.interaction?.activities)
        #expect(state.meetingCall?.id == call && state.meetingCall?.phase == .connected)
        #expect(activities.polls.first?.selections == [1] && activities.polls.first?.isOpen == false)
        #expect(activities.messages.first?.text == "hello")
        #expect(activities.reactions.first?.emoji == "👍")
        #expect(activities.artifacts.allSatisfy { $0.phase == "active" })
        #expect(activities.attendanceReportEnabled == true)
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
