import AppCore
import AVFoundation
import ChatKit
import DesignSystem
import Foundation
import Testing
@testable import MacHost

/// The menu bar's Call menu follows the call holding the device, on whichever
/// account, and acts on that call only.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CallMenuModelTests {
    private let me = Member.ID("self")
    private let peer = Member(id: Member.ID("peer"), kind: .human, displayName: "Peer")
    private var conversation: Conversation {
        Conversation(id: Conversation.ID("opaque-dm"), kind: .directMessage, members: [me, peer.id])
    }

    @Test func aCallOnAnotherAccountIsTheOneTheMenuFollows() async throws {
        let (selected, _) = await ready()
        let (other, service) = await ready()
        let model = CallMenuModel()
        model.start { sources([selected, other], selected: selected) }
        #expect(model.menu?.callID == nil)
        #expect(model.menu?.entries.allSatisfy { !$0.isEnabled } == true)

        let id = try #require(other.startCall(in: conversation, members: [peer], me: me))
        service.publish(id, .connected)
        // The menu follows the call through observation, so it can show the
        // call while still connecting before it shows it connected: wait for
        // the whole state, not only the call's arrival.
        #expect(await eventually {
            model.menu?.callID == id && model.menu?.entries.map(\.isEnabled) == [true, true]
        })

        model.toggleMute()
        #expect(other.call?.isMuted == true)
        #expect(selected.call == nil)
        model.hangUp()
        #expect(other.isEnding || other.call?.phase == .ended)
        #expect(await eventually { model.menu?.callID == nil })
        await selected.stop()
        await other.stop()
    }

    /// A menu drawn for one call acts on that call, even when another
    /// account's call began before the menu caught up.
    @Test func itActsOnlyOnTheCallItShowed() async throws {
        let (first, service) = await ready()
        let (second, _) = await ready()
        let model = CallMenuModel()
        model.start { sources([second, first], selected: second) }
        let shown = try #require(first.startCall(in: conversation, members: [peer], me: me))
        service.publish(shown, .connected)
        #expect(await eventually { model.menu?.callID == shown })
        // Synchronously, before the menu can follow it: a call on the
        // account listed first now holds the device too.
        try #require(second.startCall(in: conversation, members: [peer], me: me) != nil)
        model.toggleMute()
        #expect(first.call?.isMuted == true)
        #expect(second.call?.isMuted == false)
        model.hangUp()
        #expect(first.call?.phase == .ended)
        #expect(second.call?.phase == .connecting)
        await first.stop()
        await second.stop()
    }

    private func sources(
        _ all: [AudioCallController], selected: AudioCallController
    ) -> (all: [CallMenuModel.Source], selected: CallMenuModel.Source?) {
        (
            all.map { CallMenuModel.Source(calls: $0, video: nil) },
            CallMenuModel.Source(calls: selected, video: nil)
        )
    }

    @Test func noAccountThatCanCallDrawsNoMenu() {
        let calls = AudioCallController()
        #expect(CallMenuModel.menu(all: [.init(calls: calls, video: nil)], selected: nil) == nil)
        #expect(CallMenuModel.menu(all: [], selected: nil) == nil)
    }

    @Test func theHandCommandUsesTheCallShownByTheMenuAcrossAccounts() async throws {
        let (selected, selectedService) = await ready()
        let (calls, service) = await ready()
        let model = CallMenuModel()
        model.start { sources([selected, calls], selected: selected) }
        let id = try #require(calls.startCall(in: conversation, members: [peer], me: me))
        service.publish(id, .connected)
        service.allowHands(in: id)
        #expect(await eventually {
            model.menu?.callID == id
                && model.menu?.entries.contains { $0.item == .toggleHand && $0.isEnabled } == true
        })
        model.toggleHandRaised()
        #expect(await eventually {
            model.menu?.entries.contains {
                $0.item == .toggleHand && $0.title == "Lower Hand" && $0.isEnabled
            } == true
        })
        model.toggleHandRaised()
        #expect(await eventually { service.handChanges.count == 2 })
        #expect(service.handChanges.map(\.call) == [id, id])
        #expect(service.handChanges.map(\.raised) == [true, false])
        #expect(selectedService.handChanges.isEmpty)
        await selected.stop()
        await calls.stop()
    }

    @Test func cameraAndSharingAreDrawnWhereTheCallsCarryVideo() async {
        let (calls, _) = await ready()
        let video = CallVideoController()
        let source = CallMenuModel.Source(calls: calls, video: video)
        #expect(CallMenuModel.menu(all: [source], selected: source)?.entries.map(\.item) == [.mute, .endCall])
        video.isAvailable = true
        #expect(CallMenuModel.menu(all: [source], selected: source)?.entries.map(\.item) == [
            .mute, .camera, .shareScreen, .endCall
        ])
        await calls.stop()
    }

    @Test func preJoinDeviceReadinessUsesDiscoveryAndAuthorization() {
        #expect(CallMeetingPreparationDevices.status(hasDevice: true, authorization: .authorized) == .ready)
        #expect(CallMeetingPreparationDevices.status(hasDevice: true, authorization: .notDetermined) ==
            .needsPermission)
        #expect(CallMeetingPreparationDevices.status(hasDevice: true, authorization: .denied) == .accessOff)
        #expect(CallMeetingPreparationDevices
            .status(hasDevice: true, authorization: .restricted) == .accessOff)
        #expect(CallMeetingPreparationDevices
            .status(hasDevice: false, authorization: .authorized) == .unavailable)
    }

    @Test func cameraGestureOnlyRaisesAKnownLoweredHandInTheBoundCall() async throws {
        let (calls, service) = await ready()
        let id = try #require(calls.startCall(in: conversation, members: [peer], me: me))
        service.publish(id, .connected)
        service.allowHands(in: id)
        #expect(await eventually { calls.interaction?.canRaiseHand == true })
        #expect(calls.localHandIsRaised == nil)
        calls.raiseHandIfLowered(in: id)
        service.publishLocalHand(false, callID: id)
        #expect(await eventually { calls.localHandIsRaised == false })
        calls.raiseHandIfLowered(in: UUID())
        await Task.yield()
        #expect(service.handChanges.isEmpty)
        calls.raiseHandIfLowered(in: id)
        #expect(await eventually { calls.localHandIsRaised == true })
        calls.raiseHandIfLowered(in: id)
        await Task.yield()
        #expect(service.handChanges.map(\.call) == [id])
        #expect(service.handChanges.map(\.raised) == [true])
        await calls.stop()
    }

    @Test func videoEffectsFollowTheActiveCameraAndRejectAnOldMediaRoute() async throws {
        let (calls, service) = await ready()
        let id = try #require(calls.startCall(in: conversation, members: [peer], me: me))
        let video = CallVideoController(), audio = CallAudioDeviceController()
        var presented: [AVCaptureDevice.SystemUserInterface] = []
        func actions(for callID: UUID) -> AudioCallActions {
            var actions = AudioCallActions(accept: {}, decline: {}, toggleMute: {}, hangUp: {})
            CallSystemMediaControls.add(
                to: &actions,
                callID: callID,
                calls: calls,
                audio: audio,
                video: video
            ) {
                presented.append($0)
            }
            return actions
        }
        video.install(CameraRoute())
        video.turnOn()
        #expect(await eventually { video.camera?.isOn == true })
        #expect(actions(for: id).openVideoEffects == nil)
        service.publish(id, .connected)
        #expect(await eventually { calls.call?.phase == .connected })
        #expect(actions(for: UUID()).openVideoEffects == nil)
        let open = try #require(actions(for: id).openVideoEffects)
        open()
        video.install(CameraRoute())
        #expect(actions(for: id).openVideoEffects == nil)
        video.turnOn()
        #expect(await eventually { video.camera?.isOn == true })
        open()
        #expect(presented == [.videoEffects])
        video.clear()
        await calls.stop()
    }

    @Test func micModeFollowsTheExactUnmutedCallAndLiveAudioRoute() async throws {
        let (calls, service) = await ready()
        let id = try #require(calls.startCall(in: conversation, members: [peer], me: me))
        let video = CallVideoController(), audio = CallAudioDeviceController()
        var presented: [AVCaptureDevice.SystemUserInterface] = []
        var levelReads = 0
        func actions() -> AudioCallActions {
            var actions = AudioCallActions(accept: {}, decline: {}, toggleMute: {}, hangUp: {})
            CallSystemMediaControls.add(to: &actions, callID: id, calls: calls, audio: audio, video: video) {
                presented.append($0)
            }
            return actions
        }
        service.publish(id, .connected)
        #expect(await eventually { calls.call?.phase == .connected })
        #expect(actions().openMicrophoneModes == nil)
        audio.install(SystemMediaTestAudioRoute()) {
            levelReads += 1
            return 0.1
        }
        #expect(await eventually { audio.microphoneModeScope != nil })
        let level = try #require(actions().microphoneLevel)
        let input = await level.read()
        #expect(!level.isMuted && input != nil)
        let open = try #require(actions().openMicrophoneModes)
        open()
        calls.toggleMute()
        #expect(actions().openMicrophoneModes == nil)
        #expect(actions().microphoneLevel?.isMuted == true)
        let mutedLevel = await level.read()
        #expect(mutedLevel == nil && levelReads == 1)
        open()
        audio.install(SystemMediaTestAudioRoute())
        #expect(await eventually { audio.microphoneModeScope != nil && !calls.isUpdatingMute })
        calls.toggleMute()
        #expect(await eventually { actions().openMicrophoneModes != nil })
        open()
        #expect(presented == [.microphoneModes])
        audio.clear()
        await calls.stop()
    }

    @Test func voiceOverHearsWhoseUnreadCountItIs() {
        #expect(MenuBarLabel.spokenLabel(unread: 3) == "Kibble, 3 unread")
        #expect(MenuBarLabel.spokenLabel(unread: 1) == "Kibble, 1 unread")
        #expect(MenuBarLabel.spokenLabel(unread: 0) == "Kibble")
    }

    @Test func speakerTestActionFollowsTheConnectedCallAndExactAudioRoute() async throws {
        let (calls, service) = await ready()
        let id = try #require(calls.startCall(in: conversation, members: [peer], me: me))
        let playback = SpeakerPlaybackFixture()
        let audio = CallAudioDeviceController(
            preferences: nil, speakerPlayback: playback, defaultOutput: { "speaker" }
        )
        let video = CallVideoController()
        func action() -> CallSpeakerTestAction? {
            var actions = AudioCallActions(accept: {}, decline: {}, toggleMute: {}, hangUp: {})
            CallSystemMediaControls.add(to: &actions, callID: id, calls: calls, audio: audio, video: video)
            return actions.speakerTest
        }
        audio.install(SystemMediaTestAudioRoute())
        #expect(await eventually { audio.speakerTestScope != nil })
        #expect(action() == nil)
        service.publish(id, .connected)
        #expect(await eventually { calls.call?.phase == .connected })
        let oldAction = try #require(action())
        audio.install(SystemMediaTestAudioRoute())
        #expect(await eventually { audio.speakerTestScope != nil })
        oldAction.toggle()
        #expect(!audio.isTestingSpeaker)
        let currentAction = try #require(action())
        currentAction.toggle()
        #expect(await eventually { playback.devices == ["speaker"] })
        #expect(action()?.isPlaying == true && calls.call?.isMuted == false)
        service.publish(id, .ended)
        #expect(await eventually { calls.call?.phase == .ended })
        #expect(action() == nil)
        audio.clear()
        currentAction.toggle()
        #expect(!audio.isTestingSpeaker && playback.stopCount == 1)
        await calls.stop()
    }

    private func ready() async -> (AudioCallController, MenuCallService) {
        let service = MenuCallService(recipient: AudioCallRecipient(
            conversationID: conversation.id, memberID: peer.id, displayName: "Peer"
        ))
        let calls = AudioCallController()
        calls.start(service: service)
        #expect(await eventually { calls.canCall(conversation: conversation, members: [peer], me: me) })
        return (calls, service)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 400 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

private struct SystemMediaTestAudioRoute: CallAudioRouting {
    func snapshot() async -> CallAudioDevices {
        CallAudioDevices(
            microphones: [.init(id: "microphone", name: "Microphone")],
            speakers: [.init(id: "speaker", name: "Speaker")]
        )
    }

    func select(_: String, microphone _: Bool) async -> Bool {
        false
    }

    func persistentID(of _: String, microphone _: Bool) async -> String? {
        nil
    }

    func restore(_: String, microphone _: Bool) async -> Bool {
        false
    }
}

/// A call service the test moves through its phases by hand.
@MainActor
private final class MenuCallService: CallInteractionService {
    let events: AsyncStream<AudioCallEvent>
    private let continuation: AsyncStream<AudioCallEvent>.Continuation
    private let recipient: AudioCallRecipient
    private let localDevice = UUID()
    private(set) var handChanges: [(call: UUID, raised: Bool)] = []

    init(recipient: AudioCallRecipient) {
        self.recipient = recipient
        (events, continuation) = AsyncStream.makeStream(of: AudioCallEvent.self)
    }

    func startListening() async throws {
        continuation.yield(.recipientsChanged([recipient]))
    }

    func startOutgoing(to _: AudioCallRecipient, callID _: UUID) async throws {}
    func accept(callID _: UUID) async throws {}
    func decline(callID _: UUID) async throws {}
    func hangUp(callID _: UUID) async throws {}
    func setMuted(_: Bool, callID _: UUID) async throws {}

    func setHandRaised(_ raised: Bool, callID: UUID) async throws {
        handChanges.append((callID, raised))
        publishLocalHand(raised, callID: callID)
    }

    func publishLocalHand(_ raised: Bool, callID: UUID) {
        continuation.yield(.participantsChanged(callID: callID, participants: [
            CallParticipantDevice(id: localDevice, isLocal: true, handRaised: raised)
        ]))
    }

    func allowHands(in id: UUID) {
        continuation.yield(.interactionChanged(callID: id, state: CallInteractionState(canRaiseHand: true)))
    }

    func stop() async {
        continuation.finish()
    }

    func publish(_ id: UUID, _ phase: AudioCallPhase) {
        continuation.yield(.snapshot(AudioCallSnapshot(
            id: id, recipient: recipient, direction: .outgoing, phase: phase
        )))
    }
}
