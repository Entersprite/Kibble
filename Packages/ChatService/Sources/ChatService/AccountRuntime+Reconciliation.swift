import ChatAPI
import ChatKit
import ChatRules
import Foundation

extension AccountRuntime {
    func invalidateQueries(for event: ChatEvent) {
        switch event {
        case let .conversationsChanged(rows):
            worldVersion = UUID()
            reads.directoryCompletedAt = nil
            historyWorldVersion = UUID()
            let current = Set(rows.map(\.id))
            historyVersions = historyVersions.filter { current.contains($0.key) }
        case .conversationUpdated, .messageUpdated, .messageDeleted, .gap(scope: .conversation, reason: _),
             .conversationHistoryInvalidated:
            Self.fencedConversations(by: event).forEach(invalidate)
        case let .conversationRemoved(id, _):
            worldVersion = UUID()
            reads.directoryCompletedAt = nil
            invalidate(id)
        case .historyInvalidated, .gap(scope: .everything, reason: _):
            worldVersion = UUID()
            reads.directoryCompletedAt = nil
            historyWorldVersion = UUID()
        case let .reactionChanged(id, _):
            // Reaction events carry only a message ID. Fence the conversation
            // the canonical store holds it in; a message it does not hold yet
            // may be in any read, so fence all in-flight history rather than
            // guessing its conversation from ID syntax.
            if let conversation = try? storage.conversationID(containing: id) {
                invalidate(conversation)
            } else {
                historyWorldVersion = UUID()
            }
        default: break
        }
    }

    /// The conversations whose in-flight history reads an event fences.
    private static func fencedConversations(by event: ChatEvent) -> [Conversation.ID] {
        switch event {
        case let .conversationUpdated(row): [row.id]
        case let .messageUpdated(message): [message.conversationID]
        case let .messageDeleted(_, id), let .gap(scope: .conversation(id), reason: _): [id]
        case let .conversationHistoryInvalidated(ids): ids
        default: []
        }
    }

    private func invalidate(_ id: Conversation.ID) {
        historyVersions[id] = UUID()
    }

    func reconcileWorld(backend: any ChatBackend, epoch: UUID) async throws -> [Conversation] {
        try checkEpoch(epoch)
        let version = worldVersion
        let baseline = try storage.conversations()
        let snapshot = try await withProviderWork(epoch: epoch) {
            try await backend.loadConversationSnapshot()
        }
        try checkEpoch(epoch)
        guard version == worldVersion else {
            if checkpointedBackend != nil,
               reads.directoryCompletedAt != nil {
                return try storage.conversations()
            }
            return try await fetchWorld(backend: backend, epoch: epoch)
        }
        let rows = try snapshot.merging(current: storage.conversations(), baseline: baseline)
        let event = ChatEvent.conversationsChanged(rows)
        if try Set(rows) != Set(storage.conversations()) {
            try await commitQuery(event)
        }
        try recordResourceSync(.init(resource: .directory, phase: .ready))
        requestBackfill()
        return try storage.conversations()
    }

    func reconcileMessages(
        in conversation: Conversation.ID, before: Message.ID?, thread: MessageThread.ID? = nil,
        backend: any ChatBackend, epoch: UUID
    ) async throws -> MessagePage {
        try checkEpoch(epoch)
        let version = historyVersions[conversation]
        let world = historyWorldVersion
        let snapshot: ThreadMessagesSnapshot = try await withHistoryWork(in: conversation, epoch: epoch) {
            if let thread {
                return try await backend.loadThreadSnapshot(thread, in: conversation)
            }
            return try await ThreadMessagesSnapshot(
                messages: backend.loadMessages(in: conversation, before: before), isComplete: false
            )
        }
        try checkEpoch(epoch)
        guard world == historyWorldVersion, version == historyVersions[conversation] else {
            return try await fetchMessages(
                in: conversation, before: before, thread: thread, backend: backend, epoch: epoch
            )
        }
        let update = try MessageHistoryUpdate(
            messages: snapshot.messages, conversationID: conversation, threadID: thread,
            isComplete: snapshot.isComplete
        )
        let cursor = try await commitQuery(.historyLoaded(update))
        historyVersions[conversation] = UUID()
        try recordResourceSync(.init(resource: .history, conversationID: conversation, phase: .ready))
        return MessagePage(
            messages: snapshot.messages, nextCursor: nil, isComplete: snapshot.isComplete,
            checkpoint: cursor
        )
    }

    func reconcileFollowedThreads(backend: any ChatBackend, epoch: UUID) async throws -> [Message] {
        try checkEpoch(epoch)
        let world = historyWorldVersion
        let versions = historyVersions
        let rows = try await withProviderWork(epoch: epoch) { try await backend.loadFollowedThreads() }
        try checkEpoch(epoch)
        guard world == historyWorldVersion, rows.allSatisfy({
            versions[$0.conversationID] == historyVersions[$0.conversationID]
        }) else { return try await fetchFollowedThreads(backend: backend, epoch: epoch) }
        let update = try MessageHistoryUpdate(messages: rows, conversationID: nil, keepsReactions: true)
        try await commitQuery(.historyLoaded(update))
        for row in rows {
            historyVersions[row.conversationID] = UUID()
        }
        try recordResourceSync(.init(resource: .followedThreads, phase: .ready))
        return rows
    }

    @discardableResult
    private func commitQuery(_ event: ChatEvent) async throws -> ServiceCursor {
        do {
            return try appendAndPublish(event, live: false)
        } catch {
            await quarantine(.storage)
            throw error
        }
    }
}
