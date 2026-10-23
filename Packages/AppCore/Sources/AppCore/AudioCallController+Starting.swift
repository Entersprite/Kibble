import ChatKit
import DesignSystem
import Foundation

/// Which conversations can be called or joined, and starting or joining one:
/// a DM through its person, a group or space through the conversation itself.
public extension AudioCallController {
    func canCall(conversation: Conversation, members: [Member], me: Member.ID?) -> Bool {
        if callsConversation(conversation) {
            return true
        }
        guard let recipient = eligibleRecipient(in: conversation, me: me) else { return false }
        return members.first(where: { $0.id == recipient })?.kind == .human
    }

    /// Scene projection already has a keyed directory; avoid copying and
    /// scanning every member for each conversation on every UI update.
    func canCall(
        conversation: Conversation, directory: [Member.ID: Member], me: Member.ID?
    ) -> Bool {
        if callsConversation(conversation) {
            return true
        }
        guard let recipient = eligibleRecipient(in: conversation, me: me) else { return false }
        return directory[recipient]?.kind == .human
    }

    /// Whether Join can be offered here: the service joins without ringing
    /// anyone, and rechecks that the call is still going on when asked. Only
    /// a fresh observation that a call is going on should show it.
    func canJoin(conversation: Conversation, directory: [Member.ID: Member], me: Member.ID?) -> Bool {
        if callsConversation(conversation) {
            return true
        }
        guard supportsExistingJoin, existingJoinService != nil,
              let recipient = eligibleRecipient(in: conversation, me: me) else { return false }
        return directory[recipient]?.kind == .human
    }

    /// The conversation of the call this session is in, from the start of the
    /// attempt until it is over: where the header offers Return to Call.
    var activeConversationID: Conversation.ID? {
        guard let call, !call.phase.isTerminal, call.phase != .incoming else { return nil }
        return call.conversationID
    }

    /// Returns the new call's ID, or nil when no call started: one is already
    /// going on, and its window was raised instead, or this conversation
    /// cannot be called. A group or space call is quiet: nobody is rung.
    @discardableResult
    func startCall(in conversation: Conversation, members: [Member], me: Member.ID?) -> UUID? {
        if raiseCurrentCall() {
            return nil
        }
        if callsConversation(conversation), let service = conversationService {
            let target = target(for: conversation, members: members, me: me)
            return begin(AudioCallSession(ConversationCallSnapshot(
                id: UUID(), target: target, phase: .connecting
            ))) { id in try await service.startConversationCall(to: target, callID: id) }
        }
        guard canCall(conversation: conversation, members: members, me: me),
              let service, let recipient = recipients[conversation.id] else { return nil }
        return begin(AudioCallSession(AudioCallSnapshot(
            id: UUID(), recipient: recipient, direction: .outgoing, phase: .connecting
        ))) { id in try await service.startOutgoing(to: recipient, callID: id) }
    }

    /// Joins the call going on in `conversation` without ringing anyone. The
    /// service refuses, and the window says so, when it has ended meanwhile;
    /// a join never starts a replacement.
    @discardableResult
    func joinCall(in conversation: Conversation, members: [Member], me: Member.ID?) -> UUID? {
        if raiseCurrentCall() {
            return nil
        }
        if callsConversation(conversation), let service = conversationService {
            let target = target(for: conversation, members: members, me: me)
            return begin(AudioCallSession(
                ConversationCallSnapshot(id: UUID(), target: target, phase: .connecting), isJoining: true
            )) { id in try await service.joinConversationCall(to: target, callID: id) }
        }
        let directory = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard canJoin(conversation: conversation, directory: directory, me: me),
              let service = existingJoinService, let recipient = recipients[conversation.id]
        else { return nil }
        return begin(AudioCallSession(
            AudioCallSnapshot(id: UUID(), recipient: recipient, direction: .outgoing, phase: .connecting),
            isJoining: true
        )) { id in try await service.joinExisting(to: recipient, callID: id) }
    }

    /// Raises the window of the call already going on instead of starting one.
    func showCurrentCall() {
        guard call != nil else { return }
        windowRequests += 1
    }
}

extension AudioCallController {
    var conversationService: (any ConversationAudioCallService)? {
        service as? any ConversationAudioCallService
    }

    var existingJoinService: (any ExistingAudioCallService)? {
        service as? any ExistingAudioCallService
    }

    private func eligibleRecipient(in conversation: Conversation, me: Member.ID?) -> Member.ID? {
        guard isAvailable, !isRecovering, conversation.kind == .directMessage,
              let me, let recipient = recipients[conversation.id],
              Set(conversation.members) == Set([me, recipient.memberID]), me != recipient.memberID
        else { return nil }
        return recipient.memberID
    }

    /// A group or space this service can call. Membership is the service's to
    /// check against fresh details; a conversation never stands in for a person.
    private func callsConversation(_ conversation: Conversation) -> Bool {
        isAvailable && !isRecovering && supportsConversationCalls && conversationService != nil
            && (conversation.kind == .space || conversation.kind == .groupDirectMessage)
    }

    /// The target names the conversation the way its header does.
    private func target(
        for conversation: Conversation, members: [Member], me: Member.ID?
    ) -> ConversationCallTarget {
        let directory = conversation.title == nil
            ? Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        return ConversationCallTarget(
            conversationID: conversation.id,
            displayName: Display.title(of: conversation, directory: directory, me: me)
        )
    }

    private func raiseCurrentCall() -> Bool {
        guard isEnding || call.map({ !$0.phase.isTerminal }) == true else { return false }
        windowRequests += 1
        return true
    }

    private func begin(
        _ session: AudioCallSession, _ operation: @escaping @MainActor (UUID) async throws -> Void
    ) -> UUID {
        call = session
        participants = nil
        windowRequests += 1
        let id = session.id
        runOperation(id: id) { try await operation(id) }
        return id
    }
}
