import AppCore
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

    @Test func voiceOverHearsWhoseUnreadCountItIs() {
        #expect(MenuBarLabel.spokenLabel(unread: 3) == "Kibble, 3 unread")
        #expect(MenuBarLabel.spokenLabel(unread: 1) == "Kibble, 1 unread")
        #expect(MenuBarLabel.spokenLabel(unread: 0) == "Kibble")
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

/// A call service the test moves through its phases by hand.
@MainActor
private final class MenuCallService: AudioCallService {
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
