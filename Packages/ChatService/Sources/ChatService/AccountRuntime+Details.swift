import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func dispatchDetails(
        _ request: ServiceRequest,
        backend: any ChatBackend,
        epoch: UUID
    ) async throws -> JSONValue {
        switch request.operation {
        case GetConversationDetails.operation:
            let payload = try request.decodePayload(GetConversationDetails.self)
            let value = try await mediaQuery(epoch: epoch) {
                try await backend.conversationDetails(payload.conversationID)
            } remember: { catalog, value, date in
                try Self.rememberDetails(catalog, [value], at: date)
            }
            try checkEpoch(epoch)
            return try ServiceCodec.value(value)
        case GetParticipants.operation:
            let payload = try request.decodePayload(GetParticipants.self)
            let value = try await mediaQuery(epoch: epoch) {
                try await backend.participants(in: payload.conversationID, after: payload.cursor)
            } remember: { catalog, value, date in
                try catalog.rememberQueryMembers(value.participants.map(\.member), at: date)
            }
            try checkEpoch(epoch)
            return try ServiceCodec.value(value)
        case BrowseSpaces.operation:
            let payload = try request.decodePayload(BrowseSpaces.self)
            let value = try await mediaQuery(epoch: epoch) {
                try await backend.browseSpaces(payload.query, after: payload.cursor)
            } remember: { catalog, value, date in
                try Self.rememberDetails(catalog, value.spaces, at: date)
            }
            try checkEpoch(epoch)
            return try ServiceCodec.value(value)
        case GetConversationPreview.operation:
            let payload = try request.decodePayload(GetConversationPreview.self)
            return try await previewResult(payload, backend: backend, epoch: epoch)
        case LoadThread.operation:
            let payload = try request.decodePayload(LoadThread.self)
            let value = try await fetchMessages(
                in: payload.conversationID, before: nil, thread: payload.threadID, backend: backend,
                epoch: epoch, interactive: true
            )
            try checkEpoch(epoch)
            return try ServiceCodec.value(value)
        default: return try await dispatchDetailActions(request, backend: backend, epoch: epoch)
        }
    }

    private func previewResult(
        _ payload: GetConversationPreview, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        let value = try await mediaQuery(epoch: epoch, urgency: WorkUrgency(interactive: true)) {
            let preview = try await backend.conversationPreview(payload.conversationID)
            guard preview.messages.allSatisfy({ $0.conversationID == payload.conversationID }) else {
                throw ServiceFailure.invalidRequest
            }
            return preview
        } remember: { catalog, value, date in
            try catalog.rememberQueryMembers(value.members, at: date)
            try catalog.rememberQueryMedia(value.messages, at: date)
        }
        try checkEpoch(epoch)
        return try ServiceCodec.value(value)
    }

    private func dispatchDetailActions(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        switch request.operation {
        case GetMembership.operation:
            let payload = try request.decodePayload(GetMembership.self)
            let value = try await withProviderWork(epoch: epoch) {
                try await MembershipResult(backend.membership(
                    of: payload.memberID,
                    in: payload.conversationID
                ))
            }
            try checkEpoch(epoch)
            return try ServiceCodec.value(value)
        case SetNotificationSetting.operation:
            let payload = try request.decodePayload(SetNotificationSetting.self)
            try await withProviderWork(epoch: epoch) {
                try await backend.setNotificationSetting(payload.level, for: payload.conversationID)
            }
            try checkEpoch(epoch)
            return try ServiceCodec.value(ServiceUnit())
        case SetThreadFollowed.operation:
            let payload = try request.decodePayload(SetThreadFollowed.self)
            try await withProviderWork(epoch: epoch) {
                try await backend.setThreadFollowed(
                    payload.followed,
                    thread: payload.threadID,
                    in: payload.conversationID
                )
            }
            try checkEpoch(epoch)
            return try ServiceCodec.value(ServiceUnit())
        default: throw ServiceFailure.unsupportedOperation
        }
    }
}
