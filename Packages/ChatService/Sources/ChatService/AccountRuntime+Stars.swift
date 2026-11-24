import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func dispatchCollections(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        switch request.operation {
        case SetMessagePinned.operation:
            try await mutateMessagePin(request, backend: backend, epoch: epoch)
        case GetStarredMessages.operation:
            try await readStars(request, backend: backend, epoch: epoch)
        case SetMessageStarred.operation:
            try await mutateStar(request, backend: backend, epoch: epoch)
        case GetBlockedConversations.operation, UnblockConversation.operation:
            try await dispatchBlockedConversations(request, backend: backend, epoch: epoch)
        case GetBlockedPeople.operation, UnblockPerson.operation:
            try await dispatchBlockedPeople(request, backend: backend, epoch: epoch)
        case GetSyncedDrafts.operation:
            try await readSyncedDrafts(request, backend: backend, epoch: epoch)
        case WriteSyncedDraft.operation:
            try await writeSyncedDraft(request, backend: backend, epoch: epoch)
        case GetConversationSections.operation, UpdateConversationSection.operation,
             CreateConversationSection.operation, DeleteConversationSection.operation,
             MoveConversationToSection.operation:
            try await dispatchConversationSections(request, backend: backend, epoch: epoch)
        default:
            try await dispatchScheduledMessages(request, backend: backend, epoch: epoch)
        }
    }

    private func readStars(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        guard capabilities.canStarMessages else { throw ServiceFailure.unsupportedOperation }
        let payload = try request.decodePayload(GetStarredMessages.self)
        guard Self.validStarCursor(payload.cursor) else { throw ServiceFailure.invalidRequest }
        let value = try await mediaQuery(epoch: epoch, urgency: WorkUrgency(interactive: true)) {
            let page = try await backend.starredMessages(after: payload.cursor)
            let addresses = page.messages.map(MessageAddress.init)
            guard page.messages.count <= 30, page.members.count <= 30,
                  page.messages.allSatisfy({
                      !$0.isDeleted && !$0.id.rawValue.isEmpty && !$0.conversationID.rawValue.isEmpty
                          && !$0.threadID.rawValue.isEmpty
                  }),
                  Set(addresses).count == addresses.count,
                  Self.validStarCursor(page.nextCursor),
                  page.nextCursor == nil || page.nextCursor != payload.cursor else {
                throw ServiceFailure.invalidResponse
            }
            return page
        } remember: { catalog, page, date in
            try catalog.rememberQueryMembers(page.members, at: date)
            try catalog.rememberQueryMedia(page.messages, at: date)
        }
        try checkEpoch(epoch)
        return try ServiceCodec.value(value)
    }

    private func mutateStar(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        guard capabilities.canStarMessages else { throw ServiceFailure.unsupportedOperation }
        let payload = try request.decodePayload(SetMessageStarred.self)
        guard let thread = payload.address.thread, !thread.rawValue.isEmpty,
              let message = payload.address.message, !message.rawValue.isEmpty,
              !payload.address.conversation.rawValue.isEmpty else { throw ServiceFailure.invalidRequest }
        let result = try await performOperation(payload.operationID, request: request, epoch: epoch) {
            try await backend.setMessageStarred(payload.starred, at: payload.address)
            return ServiceUnit()
        }
        try checkEpoch(epoch)
        return result
    }

    private nonisolated static func validStarCursor(_ cursor: String?) -> Bool {
        guard let cursor else { return true }
        return !cursor.isEmpty && cursor.utf8.count <= 4096
    }
}
