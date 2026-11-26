import ChatKit
import Foundation
import Testing
@testable import AppCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CallArtifactPairTests {
    @Test(arguments: [true, false])
    func thePairProcessesRecordingThenTranscription(_ enabled: Bool) async throws {
        let (controller, service) = try await ready(enabled: enabled)
        try await controller.setRecordingAndTranscriptionEnabled(enabled)
        #expect(service.performedActivities == [
            CallActivity("recording", enabled: enabled), CallActivity("transcription", enabled: enabled)
        ])
        await controller.stop()
    }

    @Test(arguments: ["recording", "transcription"])
    func refusalReportsWhichPartWasConfirmedAndSendsNoRetry(_ failing: String) async throws {
        let (controller, service) = try await ready()
        let refusal = ChatError.unsupported(capability: "test-refusal")
        service.activityHandler = {
            if $0.action == failing {
                throw refusal
            }
        }
        if failing == "recording" {
            await #expect(throws: refusal) { try await controller.setRecordingAndTranscriptionEnabled(true) }
            #expect(service.performedActivities.map(\.action) == ["recording"])
        } else {
            await #expect(throws: CallArtifactPairError.transcriptionUnconfirmed) {
                try await controller.setRecordingAndTranscriptionEnabled(true)
            }
            #expect(service.performedActivities.map(\.action) == ["recording", "transcription"])
        }
        await controller.stop()
    }

    @Test func theCaptionChoiceAppliesOnlyToThePairedRecording() async throws {
        let (controller, service) = try await ready()
        try await controller.setRecordingAndTranscriptionEnabled(true, captionLanguage: "fr-FR")
        #expect(service.performedActivities == [
            CallActivity("recording", recordingCaptionLanguage: "fr-FR"), CallActivity("transcription")
        ])
        await controller.stop()
    }

    @Test func thePairRequiresBothAdvertisedActions() async throws {
        let (controller, service) = try await ready(actions: ["recording"])
        await #expect(throws: ChatError.self) {
            try await controller.setRecordingAndTranscriptionEnabled(true)
        }
        #expect(service.performedActivities.isEmpty)
        try await controller.performActivity(CallActivity("recording"))
        #expect(service.performedActivities.map(\.action) == ["recording"])
        await controller.stop()
    }

    @Test(arguments: [false, true])
    func aRefusedRecordingStopStillStopsTheTranscript(_ refuseBoth: Bool) async throws {
        let (controller, service) = try await ready(enabled: false)
        service.activityHandler = {
            if $0
                .action == "recording" ||
                refuseBoth {
                throw ChatError.unsupported(capability: "test-refusal")
            }
        }
        let failure: CallArtifactPairError = refuseBoth ? .bothUnconfirmed : .recordingUnconfirmed
        await #expect(throws: failure) { try await controller.setRecordingAndTranscriptionEnabled(false) }
        #expect(service.performedActivities == [
            CallActivity("recording", enabled: false), CallActivity("transcription", enabled: false)
        ])
        await controller.stop()
    }

    @Test func hangupWhileRecordingIsPendingPreventsTheTranscriptRequest() async throws {
        let (controller, service) = try await ready()
        let held = HeldRecording()
        service.activityHandler = { _ in
            await withCheckedContinuation { held.release = $0 }
        }
        let pair = Task { try await controller.setRecordingAndTranscriptionEnabled(true) }
        #expect(await eventually { held.release != nil })
        await #expect(throws: CancellationError.self) {
            try await controller.performActivity(CallActivity("refresh"))
        }
        controller.hangUp()
        held.release?.resume()
        held.release = nil
        await #expect(throws: CancellationError.self) { try await pair.value }
        #expect(service.performedActivities.map(\.action) == ["recording"])
        await controller.stop()
    }

    @Test(arguments: ["endConference", "removeParticipant", "blockParticipant"])
    func dismissingTheConfirmationLetsAnExplicitRemovalFinish(action: String) async throws {
        let (controller, service) = try await ready(actions: [action])
        let held = HeldRecording()
        var completed = false
        service.activityHandler = { _ in
            await withCheckedContinuation { held.release = $0 }
            try Task.checkCancellation()
            completed = true
        }
        let sheet = Task { try await controller.performActivity(CallActivity(action)) }
        #expect(await eventually { held.release != nil })
        sheet.cancel()
        held.release?.resume()
        held.release = nil
        await #expect(throws: CancellationError.self) { try await sheet.value }
        #expect(completed)
        #expect(service.performedActivities.map(\.action) == [action])
        await controller.stop()
    }

    private func ready(
        enabled: Bool = true, actions: [String] = ["recording", "transcription"]
    ) async throws -> (AudioCallController, RecordingActivityService) {
        let me = Member.ID("self")
        let peer = Member(id: .init("peer"), kind: .human, displayName: "Peer")
        let conversation = Conversation(id: .init("dm/test"), kind: .directMessage, members: [me, peer.id])
        let recipient = AudioCallRecipient(
            conversationID: conversation.id,
            memberID: peer.id,
            displayName: "Peer"
        )
        let service = RecordingActivityService(recipient: recipient)
        let calls = AudioCallController()
        calls.start(service: service)
        #expect(await eventually { calls.canCall(conversation: conversation, members: [peer], me: me) })
        let id = try #require(calls.startCall(in: conversation, members: [peer], me: me))
        service.emit(.init(id: id, recipient: recipient, direction: .outgoing, phase: .connected))
        var state = CallActivitiesState()
        state.availableActions = actions
        state.recordingCaptionLanguages = ["fr-FR"]
        state.artifacts = ["recording", "transcription"].map {
            CallArtifact(kind: $0, phase: enabled ? "stopped" : "active")
        }
        var interaction = CallInteractionState()
        interaction.activities = state
        service.continuation.yield(.interactionChanged(callID: id, state: interaction))
        #expect(await eventually { calls.call?.phase == .connected && calls.interaction == interaction })
        return (calls, service)
    }

    private final class HeldRecording {
        var release: CheckedContinuation<Void, Never>?
    }
}

private final class RecordingActivityService: RecordingAudioService, CallActivitiesService {
    var performedActivities: [CallActivity] = []
    var activityHandler: ((CallActivity) async throws -> Void)?

    func performCallActivity(_ activity: CallActivity, callID _: UUID) async throws {
        performedActivities.append(activity)
        try await activityHandler?(activity)
    }
}
