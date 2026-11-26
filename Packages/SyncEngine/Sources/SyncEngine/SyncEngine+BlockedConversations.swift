import ChatKit
import Foundation

extension SyncEngine {
    func blockedConversations(unblocking id: Conversation.ID?) async throws -> [BlockedConversation] {
        try await inBlockedListSession { backend in
            if let id {
                try await backend.unblockConversation(id)
            } else {
                try await backend.blockedConversations()
            }
        }
    }

    func blockedPeople(unblocking id: Member.ID?) async throws -> [BlockedPerson] {
        try await inBlockedListSession { backend in
            if let id {
                try await backend.unblockPerson(id)
            } else {
                try await backend.blockedPeople()
            }
        }
    }

    private func inBlockedListSession<Row: Sendable>(
        _ read: @Sendable (any ChatBackend) async throws -> [Row]
    ) async throws -> [Row] {
        let generation = managementGeneration
        try Task.checkCancellation()
        let rows = try await read(backend)
        try Task.checkCancellation()
        guard generation == managementGeneration else { throw CancellationError() }
        return rows
    }
}
