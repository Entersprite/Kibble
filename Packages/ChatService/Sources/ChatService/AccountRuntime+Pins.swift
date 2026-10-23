import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func readMessagePins(
        in conversation: Conversation.ID, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        guard capabilities.canReadMessagePins else { throw ServiceFailure.unsupportedOperation }
        let id = UUID()
        defer { pinQueries[id] = nil }
        for _ in 0 ..< 3 {
            try checkEpoch(epoch)
            pinQueries[id] = try PendingPinRead(
                conversation: conversation,
                baseline: storage.conversation(conversation)
            )
            let value = try await withProviderWork(epoch: epoch, urgency: WorkUrgency(interactive: true)) {
                try await backend.pinnedMessages(in: conversation)
            }
            try checkEpoch(epoch)
            try Self.validatePins(value, in: conversation)
            guard pinQueries[id]?.accepts(value) == true else { continue }
            do {
                return try commitPinRead(value, in: conversation)
            } catch {
                await quarantine(.storage)
                throw error
            }
        }
        throw ServiceFailure.overloaded
    }

    private func commitPinRead(
        _ value: PinnedMessages,
        in conversation: Conversation.ID
    ) throws -> JSONValue {
        if let catalog = storage as? any ServiceMediaCatalog {
            let date = transferNow()
            try catalog.rememberQueryMembers(value.members, at: date)
            if let pins = catalog as? any ServicePinnedMediaCatalog {
                try pins.rememberPinnedMedia(value.messages, in: conversation, at: date)
            } else {
                try catalog.rememberQueryMedia(value.messages, at: date)
            }
            mediaFactsVersion = UUID()
        }
        var saved = value
        saved.canModify = false
        if try (storage as? any ServiceMessagePinStorage)?.cachedMessagePins(in: conversation) != saved {
            try appendAndPublish(.messagePinsLoaded(conversationID: conversation, pins: value), live: false)
        }
        return try ServiceCodec.value(value)
    }

    func mutateMessagePin(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        let payload = try request.decodePayload(SetMessagePinned.self)
        guard capabilities.canReadMessagePins else { throw ServiceFailure.unsupportedOperation }
        guard payload.address.message != nil, payload.address.thread != nil
        else { throw ServiceFailure.invalidRequest }
        let current = try await withProviderWork(epoch: epoch) {
            try await backend.pinnedMessages(in: payload.address.conversation)
        }
        try Self.validatePins(current, in: payload.address.conversation)
        guard current.canModify else { throw ServiceFailure.notAuthorized }
        return try await performOperation(payload.operationID, request: request, epoch: epoch) {
            let value = try await backend.setMessagePinned(payload.pinned, at: payload.address)
            try Self.validatePins(value, in: payload.address.conversation)
            return value
        }
    }

    private static func validatePins(_ value: PinnedMessages, in conversation: Conversation.ID) throws {
        guard value.messages.count <= 100, value.members.count <= 512,
              Set(value.messages.map(\.id)).count == value.messages.count,
              value.messages.allSatisfy({ $0.conversationID == conversation && !$0.isDeleted })
        else { throw ServiceFailure.invalidRequest }
    }
}
