import ChatKit
import Foundation

public extension SyncEngine {
    func reloadConversationDirectory() async throws {
        let version = managementScope
        let conversations = try await backend.loadConversations()
        try checkManagementScope(version)
        try applyConversationSnapshot(conversations)
        worldLoaded()
    }

    func searchConversationPeople(_ query: String) async throws -> [Member] {
        let version = managementScope
        let people = try await backend.searchPeople(query)
        try checkManagementScope(version)
        return people
    }

    func createConversation(_ draft: ConversationDraft) async throws -> ConversationCreationResult {
        conversationMutationVersion += 1
        defer { conversationMutationVersion += 1 }
        let version = managementScope
        let result = try await backend.createConversation(draft)
        try checkManagementScope(version, mutations: false)
        try store.apply([.restoreConversation(result.conversation)])
        return result
    }

    func loadConversationDetails(_ id: Conversation.ID) async throws -> ConversationDetails {
        let version = managementScope
        let details = try await backend.conversationDetails(id)
        try checkManagementScope(version)
        guard details.conversation.id == id else { throw ChatError.decoding("The conversation changed.") }
        if details.membership == .joined {
            try store.apply([.upsertConversation(details.conversation)])
        }
        return details
    }

    func loadParticipants(
        in id: Conversation.ID,
        after cursor: String?
    ) async throws -> ConversationParticipantPage {
        let version = managementScope
        let page = try await backend.participants(in: id, after: cursor)
        try checkManagementScope(version)
        return page
    }

    func browseSpaces(
        _ query: SpaceDirectoryQuery,
        after cursor: String?
    ) async throws -> SpaceDirectoryPage {
        let version = managementScope
        let page = try await backend.browseSpaces(query, after: cursor)
        try checkManagementScope(version)
        return page
    }

    func mutateConversation(
        _ mutation: ConversationMutation,
        in id: Conversation.ID,
        operationID: String,
        expectedRevision: String?
    ) async throws -> ConversationMutationResult {
        invalidateConversationSnapshot(id)
        defer { invalidateConversationSnapshot(id) }
        let version = managementScope
        let result = try await backend.mutateConversation(
            mutation,
            in: id,
            operationID: operationID,
            expectedRevision: expectedRevision
        )
        try checkManagementScope(version, mutations: false)
        guard result.operationID == operationID,
              result.details == nil || result.details?.conversation.id == id else {
            throw ChatError.decoding("The service returned a different operation.")
        }
        if result.isConfirmed, version.mutation == conversationMutationVersion,
           let details = result.details, details.membership == .joined {
            try store.apply([.upsertConversation(details.conversation)])
        }
        return result
    }

    private var managementScope: ManagementScope {
        ManagementScope(mutation: conversationMutationVersion, lifecycle: managementGeneration)
    }

    private func checkManagementScope(_ version: ManagementScope, mutations: Bool = true) throws {
        try Task.checkCancellation()
        guard version.lifecycle == managementGeneration,
              !mutations || version.mutation == conversationMutationVersion else { throw CancellationError() }
    }
}

private struct ManagementScope {
    var mutation: Int
    var lifecycle: Int
}
