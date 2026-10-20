import ChatAPI
import ChatKit
import ChatRules
import Foundation

extension AccountRuntime {
    func invalidateQueries(for event: ChatEvent) {
        switch event {
        case let .conversationsChanged(rows):
            worldVersion = UUID()
            historyWorldVersion = UUID()
            let current = Set(rows.map(\.id))
            historyVersions = historyVersions.filter { current.contains($0.key) }
        case let .conversationUpdated(row): invalidate(row.id)
        case let .conversationRemoved(id, _), let .conversationUnreadMarkChanged(id, _),
             let .readStateChanged(id, _, _), let .unreadThreadsChanged(id, _),
             let .meetingMetadataChanged(id, _): invalidate(id)
        case let .messageReceived(message), let .messageUpdated(message): invalidate(message.conversationID)
        case let .messageDeleted(_, id): invalidate(id)
        case .gap(scope: .everything, reason: _):
            worldVersion = UUID()
            historyWorldVersion = UUID()
        case let .gap(scope: .conversation(id), reason: _): invalidate(id)
        case let .reactionChanged(id, _):
            // Reaction events carry only a message ID; fence all in-flight
            // history rather than guessing its conversation from ID syntax.
            _ = id
            historyWorldVersion = UUID()
        default: break
        }
    }

    private func invalidate(_ id: Conversation.ID) {
        worldVersion = UUID()
        historyVersions[id] = UUID()
    }

    func fetchWorld(backend: any ChatBackend, epoch: UUID) async throws -> [Conversation] {
        for _ in 0 ..< 3 {
            try checkEpoch(epoch)
            let version = worldVersion
            let rows = try await backend.loadConversations()
            try checkEpoch(epoch)
            guard version == worldVersion else { continue }
            let event = ChatEvent.conversationsChanged(rows)
            try await commitQuery(event)
            invalidateQueries(for: event)
            requestBackfill()
            return rows
        }
        throw ServiceFailure.overloaded
    }

    func fetchMessages(
        in conversation: Conversation.ID, before: Message.ID?, thread: MessageThread.ID? = nil,
        backend: any ChatBackend, epoch: UUID
    ) async throws -> MessagePage {
        for _ in 0 ..< 3 {
            try checkEpoch(epoch)
            let version = historyVersions[conversation]
            let world = historyWorldVersion
            let snapshot: ThreadMessagesSnapshot = if let thread {
                try await backend.loadThreadSnapshot(thread, in: conversation)
            } else {
                try await ThreadMessagesSnapshot(
                    messages: backend.loadMessages(in: conversation, before: before), isComplete: false
                )
            }
            try checkEpoch(epoch)
            guard world == historyWorldVersion, version == historyVersions[conversation] else { continue }
            let update = try MessageHistoryUpdate(
                messages: snapshot.messages, conversationID: conversation, threadID: thread,
                isComplete: snapshot.isComplete
            )
            let cursor = try await commitQuery(.historyLoaded(update))
            historyVersions[conversation] = UUID()
            return MessagePage(
                messages: snapshot.messages, nextCursor: nil, isComplete: snapshot.isComplete,
                checkpoint: cursor
            )
        }
        throw ServiceFailure.overloaded
    }

    func fetchFollowedThreads(backend: any ChatBackend, epoch: UUID) async throws -> [Message] {
        for _ in 0 ..< 3 {
            try checkEpoch(epoch)
            let world = historyWorldVersion
            let versions = historyVersions
            let rows = try await backend.loadFollowedThreads()
            try checkEpoch(epoch)
            guard world == historyWorldVersion, rows.allSatisfy({
                versions[$0.conversationID] == historyVersions[$0.conversationID]
            }) else { continue }
            let update = try MessageHistoryUpdate(messages: rows, conversationID: nil, keepsReactions: true)
            try await commitQuery(.historyLoaded(update))
            for row in rows {
                historyVersions[row.conversationID] = UUID()
            }
            return rows
        }
        throw ServiceFailure.overloaded
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
