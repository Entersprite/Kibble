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
        case LoadThread.operation:
            let payload = try request.decodePayload(LoadThread.self)
            let value = try await fetchMessages(
                in: payload.conversationID, before: nil, thread: payload.threadID, backend: backend,
                epoch: epoch
            )
            try checkEpoch(epoch)
            return try ServiceCodec.value(value)
        default: return try await dispatchDetailActions(request, backend: backend, epoch: epoch)
        }
    }

    private func dispatchDetailActions(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        switch request.operation {
        case GetMembership.operation:
            let payload = try request.decodePayload(GetMembership.self)
            let value = try await MembershipResult(backend.membership(
                of: payload.memberID, in: payload.conversationID
            ))
            try checkEpoch(epoch)
            return try ServiceCodec.value(value)
        case SetNotificationSetting.operation:
            let payload = try request.decodePayload(SetNotificationSetting.self)
            try await backend.setNotificationSetting(payload.level, for: payload.conversationID)
            try checkEpoch(epoch)
            return try ServiceCodec.value(ServiceUnit())
        case SetThreadFollowed.operation:
            let payload = try request.decodePayload(SetThreadFollowed.self)
            try await backend.setThreadFollowed(
                payload.followed,
                thread: payload.threadID,
                in: payload.conversationID
            )
            try checkEpoch(epoch)
            return try ServiceCodec.value(ServiceUnit())
        default: throw ServiceFailure.unsupportedOperation
        }
    }
}
