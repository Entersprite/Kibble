import AppCore
import ChatKit
import DesignSystem
import Foundation
import Testing
@testable import MacHost

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CallCameraRequestTests {
    private let me = Member.ID("self")
    private let peer = Member(id: Member.ID("peer"), kind: .human, displayName: "Peer")
    private var conversation: Conversation {
        Conversation(id: Conversation.ID("opaque-dm"), kind: .directMessage, members: [me, peer.id])
    }

    @Test func asksOnceACallThatRingsOrIsConnectedHasACamera() {
        let id = UUID()
        let recipient = AudioCallRecipient(
            conversationID: conversation.id, memberID: peer.id, displayName: "Peer"
        )
        func call(_ phase: AudioCallPhase, _ callID: UUID = id) -> AudioCallSnapshot {
            AudioCallSnapshot(id: callID, recipient: recipient, direction: .outgoing, phase: phase)
        }
        let off = CallCameraState(devices: [])
        var on = off
        on.isOn = true
        var changing = off
        changing.isUpdating = true
        var problem = off
        problem.notice = "Video is unavailable for this call. Voice remains connected."
        func step(
            _ snapshot: AudioCallSnapshot?, _ camera: CallCameraState?, ending: Bool = false
        ) -> CallCameraRequest.Step {
            CallCameraRequest.step(for: id, call: snapshot, isEnding: ending, camera: camera)
        }
        #expect(step(call(.connecting), off) == .wait)
        #expect(step(call(.ringing), nil) == .wait)
        #expect(step(call(.connected), nil) == .wait)
        #expect(step(call(.ringing), off) == .turnOn)
        #expect(step(call(.connected), off) == .turnOn)
        #expect(step(call(.connected), changing) == .wait)
        #expect(step(call(.connected), on) == .done)
        #expect(step(call(.connected), problem) == .done)
        #expect(step(call(.connected), off, ending: true) == .done)
        #expect(step(nil, off) == .done)
        #expect(step(call(.connected, UUID()), off) == .done)
        for phase in [AudioCallPhase.ended, .declined, .failed] {
            #expect(step(call(phase), off) == .done)
        }
    }

    @Test func theCameraTurnsOnWhenTheCallRingsAndOnlyOnce() async throws {
        let (calls, service) = await ready()
        let video = CallVideoController(), route = CameraRoute(), request = CallCameraRequest()
        let id = try #require(calls.startCall(in: conversation, members: [peer], me: me))
        request.request(for: id, calls: calls, video: video)
        // The media, and with it the camera, arrive while the call connects.
        _ = video.install(route)
        try await Task.sleep(for: .milliseconds(50))
        #expect(route.starts.isEmpty)
        service.publish(id, .ringing)
        #expect(await eventually { video.camera?.isOn == true })
        #expect(route.starts == [""])
        #expect(route.sending)
        // Turned off by the person, it stays off when the call connects.
        video.toggle()
        #expect(await eventually { video.camera?.isUpdating == false })
        service.publish(id, .connected)
        try await Task.sleep(for: .milliseconds(50))
        #expect(calls.call?.phase == .connected)
        #expect(video.camera?.isOn == false)
        #expect(route.starts == [""])
        video.clear()
        await calls.stop()
    }

    @Test func aCameraThatArrivesAfterTheCallConnectsIsStillTurnedOn() async throws {
        let (calls, service) = await ready()
        let video = CallVideoController(), route = CameraRoute(), request = CallCameraRequest()
        let id = try #require(calls.startCall(in: conversation, members: [peer], me: me))
        request.request(for: id, calls: calls, video: video)
        service.publish(id, .connected)
        #expect(await eventually { calls.call?.phase == .connected })
        _ = video.install(route)
        #expect(await eventually { video.camera?.isOn == true })
        #expect(route.starts == [""])
        video.clear()
        await calls.stop()
    }

    @Test func aCallThatEndsFirstNeverTurnsTheCameraOn() async throws {
        let (calls, service) = await ready()
        let video = CallVideoController(), route = CameraRoute(), request = CallCameraRequest()
        let id = try #require(calls.startCall(in: conversation, members: [peer], me: me))
        request.request(for: id, calls: calls, video: video)
        calls.hangUp()
        #expect(await eventually { !calls.isEnding })
        // A late camera, and a late snapshot of the retired call, change nothing.
        _ = video.install(route)
        service.publish(id, .ringing)
        try await Task.sleep(for: .milliseconds(50))
        #expect(route.starts.isEmpty)
        #expect(video.camera?.isOn == false)
        // Nor does the next call, started without the camera.
        let next = try #require(calls.startCall(in: conversation, members: [peer], me: me))
        service.publish(next, .connected)
        #expect(await eventually { calls.call?.phase == .connected })
        try await Task.sleep(for: .milliseconds(50))
        #expect(route.starts.isEmpty)
        video.clear()
        await calls.stop()
    }

    private func ready() async -> (AudioCallController, ScriptedCallService) {
        let service = ScriptedCallService(recipient: AudioCallRecipient(
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

/// A call service the test moves through its phases by hand.
@MainActor
private final class ScriptedCallService: AudioCallService {
    let events: AsyncStream<AudioCallEvent>
    private let continuation: AsyncStream<AudioCallEvent>.Continuation
    private let recipient: AudioCallRecipient

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

    func stop() async {
        continuation.finish()
    }

    func publish(_ id: UUID, _ phase: AudioCallPhase) {
        continuation.yield(.snapshot(AudioCallSnapshot(
            id: id, recipient: recipient, direction: .outgoing, phase: phase
        )))
    }
}
