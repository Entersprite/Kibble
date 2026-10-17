import ChatKit
import Foundation
import Testing
@testable import AppCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AudioCallControllerTests {
    private let me = Member.ID("self")
    private let peer = Member(id: Member.ID("peer"), kind: .human, displayName: "Peer")
    private var conversation: Conversation {
        Conversation(id: Conversation.ID("opaque-dm"), kind: .directMessage, members: [me, peer.id])
    }

    private func ready() async -> (AudioCallController, RecordingAudioService) {
        let service = RecordingAudioService(recipient: AudioCallRecipient(
            conversationID: conversation.id, memberID: peer.id, displayName: "Peer"
        ))
        let controller = AudioCallController()
        controller.start(service: service)
        #expect(await eventually { controller.canCall(conversation: conversation, members: [peer], me: me) })
        return (controller, service)
    }

    @Test func outgoingIsExplicitAndRepeatedClickRaisesTheSameCall() async throws {
        let (controller, service) = await ready()
        #expect(service.operations.isEmpty)
        controller.startCall(in: conversation, members: [peer], me: me)
        let id = try #require(controller.call?.id)
        #expect(controller.call?.phase == .connecting)
        #expect(await eventually { service.operations == ["outgoing"] })
        controller.startCall(in: conversation, members: [peer], me: me)
        #expect(controller.call?.id == id)
        #expect(controller.windowRequests == 2)
        #expect(service.operations == ["outgoing"])
        await controller.stop()
    }

    @Test func outgoingRequiresActualSupportAndHumanOneToOneMembership() async {
        let (controller, _) = await ready()
        #expect(controller.canCall(conversation: conversation, directory: [peer.id: peer], me: me))
        var unsupported = conversation
        unsupported.id = Conversation.ID("unavailable")
        #expect(!controller.canCall(conversation: unsupported, members: [peer], me: me))
        #expect(!controller.canCall(conversation: unsupported, directory: [peer.id: peer], me: me))
        #expect(!controller.canCall(conversation: conversation, members: [peer], me: nil))
        #expect(!controller.canCall(conversation: conversation, members: [], me: me))
        #expect(!controller.canCall(conversation: conversation, directory: [:], me: me))
        var bot = peer
        bot.kind = .app
        #expect(!controller.canCall(conversation: conversation, members: [bot], me: me))
        #expect(!controller.canCall(conversation: conversation, directory: [bot.id: bot], me: me))
        var group = conversation
        group.kind = .groupDirectMessage
        #expect(!controller.canCall(conversation: group, members: [peer], me: me))
        group = conversation
        group.members.append(Member.ID("third"))
        #expect(!controller.canCall(conversation: group, members: [peer], me: me))
        await controller.stop()
    }

    @Test func sameTurnHangupDoesNotStartCancelledOutgoingPreparation() async {
        let (controller, service) = await ready()
        controller.startCall(in: conversation, members: [peer], me: me)
        controller.hangUp()
        #expect(await eventually { !controller.isEnding })
        #expect(service.operations == ["hangup"])
        #expect(controller.call?.phase == .ended)
        await controller.stop()
    }

    @Test func incomingIsExplicitAndClosingUnansweredDeclinesWithoutMedia() async {
        let (controller, service) = await ready()
        let incoming = service.snapshot(phase: .incoming, direction: .incoming)
        service.emit(incoming)
        #expect(await eventually { controller.call?.phase == .incoming })
        #expect(controller.windowRequests == 1)
        #expect(service.operations.isEmpty)
        controller.windowClosed()
        #expect(await eventually { service.operations == ["decline"] })
        #expect(await eventually { controller.call?.phase == .declined })
        service.emit(incoming)
        #expect(controller.windowRequests == 1)
        await controller.stop()
    }

    @Test func closeDuringAcceptCancelsAndLateConnectedCannotResurrect() async {
        let (controller, service) = await ready()
        service.suspendAccept = true
        let incoming = service.snapshot(phase: .incoming, direction: .incoming)
        service.emit(incoming)
        #expect(await eventually { controller.call?.phase == .incoming })
        controller.accept()
        #expect(await eventually { service.acceptContinuation != nil })
        controller.windowClosed()
        #expect(await eventually { service.operations == ["accept", "hangup"] })
        service.acceptContinuation?.resume()
        service.acceptContinuation = nil
        var late = incoming
        late.phase = .connected
        service.emit(late)
        #expect(await eventually { !controller.isEnding })
        #expect(controller.call?.phase == .ended)
        #expect(controller.windowRequests == 1)
        await controller.stop()
    }

    @Test func remoteEndKeepsWindowAndNextCallGetsFreshScope() async throws {
        let (controller, service) = await ready()
        controller.startCall(in: conversation, members: [peer], me: me)
        var ended = try #require(controller.call)
        ended.phase = .ended
        service.emit(ended)
        #expect(await eventually { controller.call?.phase == .ended })
        #expect(controller.windowRequests == 1)
        controller.toggleMute()
        controller.hangUp()
        controller.startCall(in: conversation, members: [peer], me: me)
        #expect(controller.call?.id != ended.id)
        #expect(controller.windowRequests == 2)
        service.emit(ended)
        #expect(controller.call?.phase == .connecting)
        await controller.stop()
    }

    @Test func failedMuteKeepsTheConfirmedStateAndShowsSafeError() async throws {
        let (controller, service) = await ready()
        controller.startCall(in: conversation, members: [peer], me: me)
        var connected = try #require(controller.call)
        connected.phase = .connected
        service.emit(connected)
        #expect(await eventually { controller.call?.phase == .connected })
        service.failMute = true
        controller.toggleMute()
        #expect(await eventually { !controller.isUpdatingMute })
        #expect(controller.call?.isMuted == false)
        #expect(controller.call?.failureMessage == "Microphone state could not be confirmed.")
        service.failMute = false
        controller.toggleMute()
        #expect(await eventually { controller.call?.isMuted == true })
        await controller.stop()
    }

    @Test func queuedSafePermissionFailureRefinesFallbackWithoutResurrectingCall() async {
        let (controller, service) = await ready()
        service.failOutgoingWithSafeSnapshot = true
        controller.startCall(in: conversation, members: [peer], me: me)
        #expect(await eventually {
            controller.call?.failureMessage == "Microphone access is required."
        })
        #expect(controller.call?.phase == .failed)
        if var stale = controller.call {
            stale.phase = .connected
            service.emit(stale)
        }
        #expect(controller.call?.phase == .failed)
        await controller.stop()
    }

    @Test func concurrentStopWaitsForCleanupAndReplacementRejectsOldEvents() async {
        let (controller, service) = await ready()
        service.suspendStop = true
        let first = Task { await controller.stop() }
        #expect(await eventually { service.stopContinuation != nil })
        var secondDone = false
        let second = Task { await controller.stop(); secondDone = true }
        await Task.yield()
        #expect(!secondDone)
        #expect(controller.call == nil)
        service.stopContinuation?.resume()
        service.stopContinuation = nil
        await first.value
        await second.value
        #expect(service.stopCount == 1)
        let replacement = RecordingAudioService(recipient: service.recipient)
        controller.start(service: replacement)
        #expect(await eventually { replacement.listenCount == 1 })
        service.emit(service.snapshot(phase: .incoming, direction: .incoming))
        #expect(controller.call == nil)
        replacement.emit(replacement.snapshot(phase: .incoming, direction: .incoming))
        #expect(await eventually { controller.call?.phase == .incoming })
        await controller.stop()
    }

    @Test func latestMuteWinsAndUnconfirmedProviderNoticeSurvivesCompletion() async throws {
        let (controller, service) = await ready()
        controller.startCall(in: conversation, members: [peer], me: me)
        var connected = try #require(controller.call)
        connected.phase = .connected
        service.emit(connected)
        #expect(await eventually { controller.call?.phase == .connected })
        service.suspendMute = true
        service.muteNotice = "Changed locally; call status unconfirmed."
        controller.toggleMute()
        #expect(await eventually { service.muteContinuations.count == 1 })
        #expect(controller.call?.isMuted == true)
        controller.toggleMute()
        #expect(await eventually { service.muteContinuations.count == 2 })
        service.muteContinuations[1].resume()
        #expect(await eventually { !controller.isUpdatingMute })
        #expect(controller.call?.isMuted == false)
        #expect(controller.call?.failureMessage == service.muteNotice)
        service.muteContinuations[0].resume()
        service.muteContinuations = []
        #expect(controller.call?.isMuted == false)
        await controller.stop()
    }

    @Test func listenerFailureSurfacesInSceneAndStartupFailureStopsService() async throws {
        let services = try FakeLaunchServices()
        let audio = RecordingAudioService(recipient: AudioCallRecipient(
            conversationID: conversation.id, memberID: peer.id, displayName: "Peer"
        ))
        audio.failListen = true
        services.sessionAudioCalls = audio
        let environment = AppEnvironment(services: services)
        await environment.start()
        #expect(await eventually { environment.sceneState.notice == "Incoming calls are unavailable." })
        await environment.signOut()
        #expect(audio.stopCount == 1)

        let failedServices = try FakeLaunchServices()
        let failedAudio = RecordingAudioService(recipient: audio.recipient)
        failedServices.sessionAudioCalls = failedAudio
        failedServices.diagnosticsRequested = true
        failedServices.startDiagnosticsFailure = ChatError.transport("diagnostics failed")
        let failedEnvironment = AppEnvironment(services: failedServices)
        await failedEnvironment.start()
        #expect(failedAudio.stopCount == 1)
        #expect(!failedEnvironment.calls.isAvailable)
    }

    @Test func appSessionStartsListenerAndSignOutStopsIt() async throws {
        let services = try FakeLaunchServices()
        let audio = RecordingAudioService(recipient: AudioCallRecipient(
            conversationID: conversation.id, memberID: peer.id, displayName: "Peer"
        ))
        services.sessionAudioCalls = audio
        let environment = AppEnvironment(services: services)
        await environment.start()
        #expect(await eventually { audio.listenCount == 1 })
        audio.emit(audio.snapshot(phase: .incoming, direction: .incoming))
        #expect(await eventually { environment.calls.call != nil })
        await environment.signOut()
        #expect(audio.stopCount == 1)
        #expect(environment.calls.call == nil)
        #expect(!environment.calls.isAvailable)
    }

    @Test func laterListenerFailureClearsOnlyWhenReadyAndOldSessionCannotSetNotice() async {
        let (controller, service) = await ready()
        service.continuation.yield(.listenerChanged(isListening: false))
        #expect(await eventually { controller.listenerFailure == "Incoming calls are unavailable." })
        service.continuation.yield(.recipientsChanged([service.recipient]))
        #expect(controller.listenerFailure != nil)
        service.continuation.yield(.listenerChanged(isListening: true))
        #expect(await eventually { controller.listenerFailure == nil })
        await controller.stop()
        let replacement = RecordingAudioService(recipient: service.recipient)
        controller.start(service: replacement)
        #expect(await eventually { replacement.listenCount == 1 })
        service.continuation.yield(.listenerChanged(isListening: false))
        #expect(controller.listenerFailure == nil)
        await controller.stop()
    }
}

@MainActor
final class RecordingAudioService: AudioCallService {
    let events: AsyncStream<AudioCallEvent>
    let continuation: AsyncStream<AudioCallEvent>.Continuation
    let recipient: AudioCallRecipient
    var operations: [String] = []
    var listenCount = 0
    var directoryUpdates: [[AudioCallRecipient]] = []
    var stopCount = 0
    var suspendAccept = false
    var suspendStop = false
    var failMute = false
    var failOutgoingWithSafeSnapshot = false
    var failListen = false
    var suspendMute = false
    var muteNotice: String?
    var latestSnapshot: AudioCallSnapshot?
    var muteContinuations: [CheckedContinuation<Void, Never>] = []
    var acceptContinuation: CheckedContinuation<Void, Never>?
    var stopContinuation: CheckedContinuation<Void, Never>?

    init(recipient: AudioCallRecipient) {
        self.recipient = recipient
        (events, continuation) = AsyncStream.makeStream(of: AudioCallEvent.self)
    }

    func startListening() async throws {
        listenCount += 1
        if failListen {
            throw ChatError.transport("private listener error")
        }
        continuation.yield(.recipientsChanged([recipient]))
    }

    func updateRecipients(_ recipients: [AudioCallRecipient]) async {
        directoryUpdates.append(recipients)
    }

    func startOutgoing(to recipient: AudioCallRecipient, callID: UUID) async throws {
        operations.append("outgoing")
        if failOutgoingWithSafeSnapshot {
            emit(AudioCallSnapshot(
                id: callID, recipient: recipient, direction: .outgoing, phase: .failed,
                failureMessage: "Microphone access is required."
            ))
            throw ChatError.transport("private provider diagnostic")
        }
    }

    func accept(callID: UUID) async throws {
        operations.append("accept")
        if suspendAccept {
            await withCheckedContinuation { acceptContinuation = $0 }
        }
    }

    func decline(callID: UUID) async throws {
        operations.append("decline")
    }

    func hangUp(callID: UUID) async throws {
        operations.append("hangup")
    }

    func setMuted(_ muted: Bool, callID: UUID) async throws {
        operations.append(muted ? "mute" : "unmute")
        if failMute {
            throw ChatError.transport("private provider error")
        }
        if suspendMute {
            if var snapshot = latestSnapshot {
                snapshot.isMuted = muted
                snapshot.failureMessage = muteNotice
                emit(snapshot)
            }
            await withCheckedContinuation { muteContinuations.append($0) }
        }
    }

    func stop() async {
        stopCount += 1
        if suspendStop {
            await withCheckedContinuation { stopContinuation = $0 }
        }
    }

    func snapshot(phase: AudioCallPhase, direction: AudioCallDirection) -> AudioCallSnapshot {
        AudioCallSnapshot(id: UUID(), recipient: recipient, direction: direction, phase: phase)
    }

    func emit(_ snapshot: AudioCallSnapshot) {
        latestSnapshot = snapshot
        continuation.yield(.snapshot(snapshot))
    }
}
