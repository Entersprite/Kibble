import ChatAPI
import ChatKit
import DesignSystem
import Foundation
import Testing
@testable import AppCore

/// Group and space calls, joining, and the roster through the one controller.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ConversationCallControllerTests {
    private let me = Member.ID("self")
    private let peer = Member(id: Member.ID("peer"), kind: .human, displayName: "Peer")
    private let other = Member(id: Member.ID("other"), kind: .human, displayName: "Other")
    private var dm: Conversation {
        Conversation(id: Conversation.ID("opaque-dm"), kind: .directMessage, members: [me, peer.id])
    }

    private var space: Conversation {
        Conversation(
            id: Conversation.ID("opaque-space"), kind: .space, title: "Design", members: [me, peer.id]
        )
    }

    private var group: Conversation {
        Conversation(
            id: Conversation.ID("opaque-group"), kind: .groupDirectMessage, members: [me, peer.id, other.id]
        )
    }

    private func ready(
        conversations: Bool = true, join: Bool = true
    ) async -> (AudioCallController, ConversationRecordingService) {
        let service = ConversationRecordingService(
            recipient: AudioCallRecipient(conversationID: dm.id, memberID: peer.id, displayName: "Peer"),
            conversations: conversations, join: join
        )
        let controller = AudioCallController()
        controller.start(service: service)
        #expect(await eventually { controller.canCall(conversation: dm, members: [peer], me: me) })
        return (controller, service)
    }

    @Test func aSpaceStartsQuietlyAsTheConversationNeverAsAMember() async throws {
        let (controller, service) = await ready()
        #expect(controller.supportsConversationCalls)
        #expect(controller.canCall(conversation: space, directory: [:], me: me))
        let id = try #require(controller.startCall(in: space, members: [peer], me: me))
        let call = try #require(controller.call)
        #expect(call.id == id)
        #expect(call.recipient == nil)
        #expect(call.conversationID == space.id)
        #expect(call.displayName == "Design")
        #expect(!call.isJoining)
        #expect(await eventually { service.operations == ["startConversation"] })
        #expect(service.targets == [ConversationCallTarget(conversationID: space.id, displayName: "Design")])
        #expect(controller.activeConversationID == space.id)
        await controller.stop()
    }

    @Test func anUntitledGroupIsNamedForItsPeople() async {
        let (controller, _) = await ready()
        controller.startCall(in: group, members: [peer, other], me: me)
        #expect(controller.call?.displayName == "Peer, Other")
        await controller.stop()
    }

    @Test func withoutConversationSupportOnlyTheDMCanBeCalled() async {
        let (controller, service) = await ready(conversations: false)
        #expect(!controller.canCall(conversation: space, directory: [:], me: me))
        #expect(!controller.canJoin(conversation: space, directory: [:], me: me))
        #expect(controller.startCall(in: space, members: [], me: me) == nil)
        #expect(controller.joinCall(in: space, members: [], me: me) == nil)
        #expect(controller.call == nil)
        #expect(service.operations.isEmpty)
        await controller.stop()
    }

    @Test func joiningAConversationSaysJoiningAndRingsNobody() async throws {
        let (controller, service) = await ready()
        controller.joinCall(in: space, members: [], me: me)
        let call = try #require(controller.call)
        #expect(call.isJoining)
        #expect(call.phase == .connecting)
        #expect(await eventually { service.operations == ["joinConversation"] })
        service.emitConversation(ConversationCallSnapshot(
            id: call.id, target: service.targets[0], phase: .connected
        ))
        #expect(await eventually { controller.call?.phase == .connected })
        // The provider's later snapshots keep the join's own framing.
        #expect(controller.call?.isJoining == true)
        await controller.stop()
    }

    @Test func aDMJoinUsesTheExistingCallPortWithoutStartingOne() async {
        let (controller, service) = await ready()
        #expect(controller.supportsExistingJoin)
        #expect(controller.canJoin(conversation: dm, directory: [peer.id: peer], me: me))
        controller.joinCall(in: dm, members: [peer], me: me)
        #expect(controller.call?.recipient?.memberID == peer.id)
        #expect(controller.call?.isJoining == true)
        #expect(await eventually { service.operations == ["joinExisting"] })
        await controller.stop()
    }

    @Test func aDMJoinNeedsTheServicesOwnSupport() async {
        let (controller, service) = await ready(join: false)
        #expect(!controller.canJoin(conversation: dm, directory: [peer.id: peer], me: me))
        #expect(controller.joinCall(in: dm, members: [peer], me: me) == nil)
        #expect(service.operations.isEmpty)
        await controller.stop()
    }

    @Test func aRefusedJoinSaysTheCallMayHaveEndedAndStartsNothing() async {
        let (controller, service) = await ready()
        service.joinFailure = ChatError.unknown("private provider text")
        controller.joinCall(in: space, members: [], me: me)
        #expect(await eventually { controller.call?.phase == .failed })
        #expect(controller.call?.failureMessage == "The call couldn’t be joined. It may have ended.")
        #expect(service.operations == ["joinConversation"])
        #expect(controller.activeConversationID == nil)
        await controller.stop()
    }

    @Test func aBusyDeviceSaysSoForAStart() async {
        let (controller, service) = await ready()
        service.startFailure = ServiceFailure.deviceBusy
        controller.startCall(in: space, members: [], me: me)
        #expect(await eventually { controller.call?.phase == .failed })
        #expect(controller.call?.failureMessage == "Another call is already using this device.")
        await controller.stop()
    }

    @Test func aSecondCallRaisesTheFirstInsteadOfStartingAnother() async throws {
        let (controller, service) = await ready()
        let first = try #require(controller.startCall(in: space, members: [], me: me))
        #expect(controller.joinCall(in: group, members: [], me: me) == nil)
        #expect(controller.startCall(in: dm, members: [peer], me: me) == nil)
        #expect(controller.call?.id == first)
        #expect(controller.windowRequests == 3)
        controller.showCurrentCall()
        #expect(controller.windowRequests == 4)
        #expect(await eventually { service.operations == ["startConversation"] })
        await controller.stop()
    }

    @Test func theRosterFollowsOnlyTheCurrentLiveCall() async throws {
        let (controller, service) = await ready()
        let id = try #require(controller.startCall(in: space, members: [], me: me))
        let devices = [CallParticipantDevice(id: UUID(), displayName: "Maya", microphoneMuted: true)]
        let foreign = [CallParticipantDevice(id: UUID(), displayName: "Someone else")]
        // Another call's roster, even arriving alone, never shows for this one.
        service.emitParticipants(callID: UUID(), foreign)
        try await Task.sleep(for: .milliseconds(30))
        #expect(controller.participants == nil)
        service.emitParticipants(callID: id, devices)
        #expect(await eventually { controller.participants == devices })
        // An unestablished roster is nil again, never an empty room.
        service.emitParticipants(callID: id, nil)
        #expect(await eventually { controller.participants == nil })
        service.emitParticipants(callID: id, devices)
        #expect(await eventually { controller.participants == devices })
        controller.hangUp()
        #expect(controller.participants == nil)
        service.emitParticipants(callID: id, devices)
        try await Task.sleep(for: .milliseconds(30))
        #expect(controller.participants == nil)
        await controller.stop()
    }

    @Test func aConversationSnapshotForAnotherCallIsIgnored() async throws {
        let (controller, service) = await ready()
        let id = try #require(controller.startCall(in: space, members: [], me: me))
        service.emitConversation(ConversationCallSnapshot(
            id: UUID(), target: ConversationCallTarget(conversationID: group.id, displayName: "Other"),
            phase: .connected
        ))
        try await Task.sleep(for: .milliseconds(30))
        #expect(controller.call?.id == id)
        #expect(controller.call?.phase == .connecting)
        await controller.stop()
    }

    @Test func theHeaderOffersReturnThenAFreshJoinThenCall() {
        #expect(ConversationCallOffer.resolve(
            inCall: true, observedActive: true, canJoin: true, canCall: true, participants: 2
        ) == .returnToCall)
        #expect(ConversationCallOffer.resolve(
            inCall: false, observedActive: true, canJoin: true, canCall: true, participants: 2
        ) == .join(participants: 2))
        #expect(ConversationCallOffer.resolve(
            inCall: false, observedActive: true, canJoin: false, canCall: true, participants: 2
        ) == .call)
        #expect(ConversationCallOffer.resolve(
            inCall: false, observedActive: false, canJoin: true, canCall: true, participants: nil
        ) == .call)
        #expect(ConversationCallOffer.resolve(
            inCall: false, observedActive: false, canJoin: true, canCall: false, participants: nil
        ) == nil)
    }
}

@MainActor
final class ConversationRecordingService: ExistingAudioCallService, ConversationAudioCallService {
    let events: AsyncStream<AudioCallEvent>
    private let continuation: AsyncStream<AudioCallEvent>.Continuation
    private let recipient: AudioCallRecipient
    private let conversations: Bool
    private let join: Bool
    private var listening = false
    var operations: [String] = []
    var targets: [ConversationCallTarget] = []
    var joinFailure: (any Error)?
    var startFailure: (any Error)?

    init(recipient: AudioCallRecipient, conversations: Bool, join: Bool) {
        self.recipient = recipient
        self.conversations = conversations
        self.join = join
        (events, continuation) = AsyncStream.makeStream(of: AudioCallEvent.self)
    }

    /// Like the service, support is known once listening has started.
    var canJoinExistingCalls: Bool {
        listening && join
    }

    var canCallConversations: Bool {
        listening && conversations
    }

    func startListening() async throws {
        listening = true
        continuation.yield(.recipientsChanged([recipient]))
        continuation.yield(.listenerChanged(isListening: true))
    }

    func startOutgoing(to _: AudioCallRecipient, callID _: UUID) async throws {
        operations.append("outgoing")
    }

    func joinExisting(to _: AudioCallRecipient, callID _: UUID) async throws {
        operations.append("joinExisting")
    }

    func startConversationCall(to target: ConversationCallTarget, callID _: UUID) async throws {
        operations.append("startConversation")
        targets.append(target)
        if let startFailure {
            throw startFailure
        }
    }

    func joinConversationCall(to target: ConversationCallTarget, callID _: UUID) async throws {
        operations.append("joinConversation")
        targets.append(target)
        if let joinFailure {
            throw joinFailure
        }
    }

    func accept(callID _: UUID) async throws {}
    func decline(callID _: UUID) async throws {}
    func hangUp(callID _: UUID) async throws {
        operations.append("hangUp")
    }

    func setMuted(_: Bool, callID _: UUID) async throws {}
    func stop() async {}

    func emitConversation(_ snapshot: ConversationCallSnapshot) {
        continuation.yield(.conversationSnapshot(snapshot))
    }

    func emitParticipants(callID: UUID, _ devices: [CallParticipantDevice]?) {
        continuation.yield(.participantsChanged(callID: callID, participants: devices))
    }
}
