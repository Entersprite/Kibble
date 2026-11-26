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
        case ReadCallHistory.operation:
            return try readCallHistory(request, epoch: epoch)
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
        default: return try await getCallAvailability(request, backend: backend, epoch: epoch)
        }
    }

    private func getCallAvailability(
        _ request: ServiceRequest, backend: any ChatBackend, epoch: UUID
    ) async throws -> JSONValue {
        guard request.operation == GetCallAvailability.operation else {
            throw ServiceFailure.unsupportedOperation
        }
        let payload = try request.decodePayload(GetCallAvailability.self)
        guard backend.capabilities.canDiscoverCalls, let calls = backend as? any CallDiscoveryBackend else {
            throw ServiceFailure.unsupportedOperation
        }
        let value = try await withProviderWork(epoch: epoch, urgency: WorkUrgency(interactive: true)) {
            try await calls.callAvailability(in: payload.conversationID)
        }
        try checkEpoch(epoch)
        guard value.conversationID == payload.conversationID else { throw ServiceFailure.invalidRequest }
        return try ServiceCodec.value(value)
    }

    private func readCallHistory(_ request: ServiceRequest, epoch: UUID) throws -> JSONValue {
        let payload = try request.decodePayload(ReadCallHistory.self)
        guard let history = storage as? any ServiceCallHistoryStorage else {
            throw ServiceFailure.unsupportedOperation
        }
        try checkEpoch(epoch)
        do {
            return try ServiceCodec.value(history.callHistory(payload.query))
        } catch is CallHistoryError {
            throw ServiceFailure.invalidRequest
        }
    }
}
