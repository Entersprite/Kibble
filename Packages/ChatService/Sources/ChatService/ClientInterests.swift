import ChatAPI
import ChatKit
import Foundation

struct ClientInterestKey: Hashable, Sendable {
    let device: ServiceDeviceID
    let session: ClientSessionID
    init(_ context: ServiceSessionContext) {
        device = context.deviceID; session = context.sessionID
    }
}

struct ClientTypingTarget: Hashable, Sendable {
    let conversation: Conversation.ID
    let thread: MessageThread.ID?
    func command(active: Bool) -> ChatCommand {
        .setTyping(conversationID: conversation, threadID: thread, isTyping: active)
    }
}

struct ClientInterestLease: Sendable {
    let id: ClientAttachmentID
    var expires: ContinuousClock.Instant
    var presence: Set<Member.ID> = []
    var conversations: Set<Conversation.ID> = []
    var active = false
    var typing: [ClientTypingTarget: ContinuousClock.Instant] = [:]
    var hints: [ClientHintScope: ClientHintStamp] = [:]
}

enum ClientHintScope: Hashable, Sendable {
    case presence, conversation, activity, typing(ClientTypingTarget)
    init?(_ command: ChatCommand) {
        switch command {
        case .watchPresence: self = .presence
        case .watchConversationActivity: self = .conversation
        case .reportActivity: self = .activity
        case let .setTyping(id, thread, _): self = .typing(.init(conversation: id, thread: thread))
        default: return nil
        }
    }
}

struct ClientHintStamp: Sendable {
    let sequence: UInt64
    let command: ChatCommand
    let retainUntil: ContinuousClock.Instant
}

struct ClientInterestSlot: Sendable {
    let generation: UInt64
    var retainedUntil: ContinuousClock.Instant
    var lease: ClientInterestLease?
}

struct ClientInterestAggregate: Sendable {
    var presence: Set<Member.ID> = []
    var conversations: Set<Conversation.ID> = []
    var active = false
    var typing: Set<ClientTypingTarget> = []
    var hasAny: Bool {
        active || !presence.isEmpty || !conversations.isEmpty || !typing.isEmpty
    }
}

struct ClientInterestWaiter: Sendable {
    let revision: UInt64
    let continuation: CheckedContinuation<Void, any Error>
    let timeout: Task<Void, Never>
}
