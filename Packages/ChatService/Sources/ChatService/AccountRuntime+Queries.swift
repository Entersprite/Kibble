import ChatAPI
import ChatKit
import Foundation

extension AccountRuntime {
    func dispatchQueries(
        _ request: ServiceRequest,
        backend: any ChatBackend,
        epoch: UUID
    ) async throws -> JSONValue {
        switch request.operation {
        case GetCapabilities.operation:
            _ = try request.decodePayload(GetCapabilities.self)
            let value = capabilities
            try checkEpoch(epoch)
            return try ServiceCodec.value(value)
        case LoadConversations.operation:
            let payload = try request.decodePayload(LoadConversations.self)
            let value = try await fetchWorld(
                backend: backend,
                epoch: epoch,
                maximumAge: payload.maximumAge ?? 0
            )
            try checkEpoch(epoch)
            return try ServiceCodec.value(value)
        case LoadMessages.operation:
            let payload = try request.decodePayload(LoadMessages.self)
            let value = try await fetchMessages(
                in: payload.conversationID, before: payload.cursor.map { Message.ID($0) },
                backend: backend, epoch: epoch, interactive: true
            )
            try checkEpoch(epoch)
            return try ServiceCodec.value(value)
        case SearchPeople.operation:
            let payload = try request.decodePayload(SearchPeople.self)
            let value = try await mediaQuery(epoch: epoch) {
                try await backend.searchPeople(payload.query)
            } remember: { catalog, value, date in
                try catalog.rememberQueryMembers(value, at: date)
            }
            try checkEpoch(epoch)
            return try ServiceCodec.value(value)
        case SearchMessages.operation:
            let payload = try request.decodePayload(SearchMessages.self)
            let value = try await mediaQuery(epoch: epoch) {
                try await backend.searchMessages(payload.query, after: payload.cursor)
            } remember: { catalog, value, date in
                try catalog.rememberQueryMedia(value.hits, at: date)
            }
            try checkEpoch(epoch)
            return try ServiceCodec.value(value)
        case LoadFollowedThreads.operation:
            _ = try request.decodePayload(LoadFollowedThreads.self)
            let value = try await fetchFollowedThreads(backend: backend, epoch: epoch)
            try checkEpoch(epoch)
            return try ServiceCodec.value(value)
        default: throw ServiceFailure.unsupportedOperation
        }
    }
}
