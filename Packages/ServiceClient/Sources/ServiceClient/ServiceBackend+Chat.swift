import ChatAPI
import ChatKit
import Foundation

public extension ServiceBackend {
    func send(_ command: ChatCommand) async throws {
        let id = if case let .sendMessage(_, _, _, localID?, _, _) = command {
            ServiceOperationID("send:\(localID)")
        } else {
            ServiceOperationID(UUID().uuidString)
        }
        do {
            let result = try await call(SendCommand(operationID: id, command: command))
            guard result.state == "succeeded" else { throw ServiceFailure.operationUnknown }
        } catch let failure as ServiceFailure
            where failure == .operationUnknown || failure == .deadlineExceeded {
            throw UncertainOperation(operationID: id.rawValue)
        }
    }

    func loadConversations() async throws -> [Conversation] {
        try await call(LoadConversations())
    }

    func loadMessages(in conversation: Conversation.ID, before: Message.ID?) async throws -> [Message] {
        try await call(LoadMessages(conversationID: conversation, cursor: before?.rawValue)).messages
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
        try await call(LoadThread(threadID: thread, conversationID: conversation)).messages
    }

    func loadThreadSnapshot(
        _ thread: MessageThread.ID,
        in conversation: Conversation.ID
    ) async throws -> ThreadMessagesSnapshot {
        let page = try await call(LoadThread(threadID: thread, conversationID: conversation))
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
        try await call(LoadFollowedThreads())
    }
}
