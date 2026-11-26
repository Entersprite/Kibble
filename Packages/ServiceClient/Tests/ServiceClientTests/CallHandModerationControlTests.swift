import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService
@testable import ServiceClient

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CallHandModerationControlTests {
    @Test func keepingTheHandRaisedCancelsTheSerializedPrompt() async throws {
        let harness = try await CallHarness.make(), account = harness.accounts[0]
        let initial = try await harness.read(account)
        let source = try #require(initial.sourceID), call = UUID()
        _ = try await harness.client().call(
            JoinMeetingCall(
                url: #require(URL(string: "https://meet.example.test/room")), callID: call, sourceID: source
            ),
            account: account.id, revision: account.currentRevision
        )
        try await callEventually { try await harness.read(account).meetingCall?.phase == .connected }
        let fixture = try #require(await harness.providers.source(account.id, device: .init("one")))
        try await fixture.setHandRaised(true, callID: call)
        let prompt = CallAutomaticHandLowering(id: UUID(), deadline: Date(timeIntervalSince1970: 42))
        fixture.offerAutomaticHandLowering(prompt, callID: call)
        try await callEventually {
            try await harness.read(account).interaction?.activities?.automaticHandLowering == prompt
        }
        _ = try await harness.client().call(
            PerformCallActivity(
                callID: call, sourceID: source, activity: CallActivity(
                    "keepHandRaised",
                    resourceID: prompt.id
                )
            ),
            account: account.id, revision: account.currentRevision
        )
        try await callEventually {
            let state = try await harness.read(account)
            return state.interaction?.activities?.automaticHandLowering == nil
                && state.participants?.first(where: \.isLocal)?.handRaised == true
        }
        await harness.service.shutdown()
    }

    @Test func moderatorClearsRaisedHandsThroughTheCallActivityService() async throws {
        let harness = try await CallHarness.make(), account = harness.accounts[0]
        let initial = try await harness.read(account)
        let source = try #require(initial.sourceID), call = UUID()
        _ = try await harness.client().call(
            JoinMeetingCall(
                url: #require(URL(string: "https://meet.example.test/room")), callID: call, sourceID: source
            ),
            account: account.id, revision: account.currentRevision
        )
        try await callEventually { try await harness.read(account).meetingCall?.phase == .connected }
        let fixture = try #require(await harness.providers.source(account.id, device: .init("one")))
        let first = CallParticipantDevice(
            id: UUID(), displayName: "Taylor", handRaised: true, handRaisedAt: Date(timeIntervalSince1970: 1)
        )
        let second = CallParticipantDevice(id: UUID(), displayName: "Maya", handRaised: true)
        fixture.setParticipantDevices([first, second], callID: call)
        try await callEventually { try await harness.read(account).participants == [first, second] }
        let commands = [
            CallActivity("lowerParticipantHand", resourceID: first.id),
            CallActivity("lowerAllHands")
        ]
        for (index, activity) in commands.enumerated() {
            _ = try await harness.client().call(
                PerformCallActivity(callID: call, sourceID: source, activity: activity),
                account: account.id, revision: account.currentRevision
            )
            try await callEventually {
                let participants = try await harness.read(account).participants
                return participants?.first?.handRaised == false && participants?.first?.handRaisedAt == nil
                    && participants?.last?.handRaised == (index == 0)
            }
        }
        try await fixture.setHandRaised(true, callID: call)
        fixture.remoteLoweredLocalHand(callID: call)
        try await callEventually {
            let state = try await harness.read(account)
            return state.interaction?.activities?.ownHandLowered != nil
                && state.participants?.first(where: \.isLocal)?.handRaised == false
        }
        await harness.service.shutdown()
    }
}
