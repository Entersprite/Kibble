import ChatAPI
import ChatKit
import Foundation

public extension ServiceBackend {
    func send(_ command: ChatCommand) async throws {
        if SendHint.accepts(command) {
            try await sendClientHint(command)
            return
        }
        let id = if case let .sendMessage(_, _, _, localID?, _, _, _) = command {
            ServiceOperationID("send:\(localID)")
        } else {
            ServiceOperationID(ClientOperationID.make())
        }
        do {
            let result = try await call(SendCommand(operationID: id, command: command))
            guard result.state == "succeeded" else { throw ServiceFailure.operationUnknown }
        } catch let failure as ServiceFailure
            where failure == .operationUnknown || failure == .deadlineExceeded {
            throw UncertainOperation(operationID: id.rawValue)
        } catch let failure as ServiceFailure where Self.definitiveSubmissionFailures.contains(failure.code) {
            throw failure
        } catch {
            // Lost, malformed and cancelled replies do not prove that the
            // service failed to dispatch. Keep the original operation handle.
            throw UncertainOperation(operationID: id.rawValue)
        }
    }

    func loadConversations() async throws -> [Conversation] {
        try await projected { try await call(LoadConversations(maximumAge: 30)) }
    }

    func loadMessages(in conversation: Conversation.ID, before: Message.ID?) async throws -> [Message] {
        try await projected { try await call(LoadMessages(
            conversationID: conversation,
            cursor: before?.rawValue
        )).messages }
    }

    func setNotificationSetting(_ level: NotificationLevel, for conversation: Conversation.ID) async throws {
        _ = try await call(SetNotificationSetting(level: level, conversationID: conversation))
    }

    func searchPeople(_ query: String) async throws -> [Member] {
        try await call(SearchPeople(query: query))
    }

    func searchMessages(
        _ query: MessageSearchQuery,
        after cursor: MessageSearchCursor?
    ) async throws -> MessageSearchPage {
        try await call(SearchMessages(query: query, cursor: cursor))
    }

    func membership(
        of member: Member.ID,
        in conversation: Conversation.ID
    ) async throws -> ConversationMembership {
        try await call(GetMembership(memberID: member, conversationID: conversation)).membership
    }

    func loadThread(_ thread: MessageThread.ID, in conversation: Conversation.ID) async throws -> [Message] {
        try await projected {
            try await call(LoadThread(threadID: thread, conversationID: conversation)).messages
        }
    }

    func loadThreadSnapshot(
        _ thread: MessageThread.ID,
        in conversation: Conversation.ID
    ) async throws -> ThreadMessagesSnapshot {
        let page = try await projected { try await call(LoadThread(
            threadID: thread,
            conversationID: conversation
        )) }
        return ThreadMessagesSnapshot(messages: page.messages, isComplete: page.isComplete)
    }

    func setThreadFollowed(
        _ followed: Bool,
        thread: MessageThread.ID,
        in conversation: Conversation.ID
    ) async throws {
        _ = try await call(SetThreadFollowed(
            followed: followed,
            threadID: thread,
            conversationID: conversation
        ))
    }

    func loadFollowedThreads() async throws -> [Message] {
        try await projected { try await call(LoadFollowedThreads()) }
    }
}

extension ServiceBackend: MessageDeliveryTrackingBackend {
    public func deliveryStatus(for localID: String) async throws -> MessageDeliveryStatus {
        do {
            let operation = try await call(
                GetOperation(operationID: ServiceOperationID("send:\(localID)")),
                timeout: 10
            )
            switch operation.state {
            case "succeeded": return .sent
            case "failed": return .failed
            case "accepted", "dispatching": return .unconfirmed
            default: return .unconfirmed
            }
        } catch let failure as ServiceFailure where failure == .operationUnknown {
            return .unconfirmed
        }
    }

    private static let definitiveSubmissionFailures: Set<String> = [
        "accountCleanupPending", "authenticationRequired", "staleAccount", "ownerBusy", "accountDisabled",
        "accountNotFound", "operationConflict", "privacyDenied", "policyUnavailable", "invalidRequest",
        "incompatibleVersion", "handshakeRequired", "notAuthorized", "accountRequired",
        "unsupportedOperation",
        "frameTooLarge", "overloaded", "duplicateRequest"
    ]
}
