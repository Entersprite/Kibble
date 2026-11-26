import ChatKit
import Foundation
import GChatBridgeCore

public extension LocalBridgeBackend {
    func loadConversations() async throws -> [Conversation] {
        try await loadConversationSnapshot().conversations
    }

    func loadConversationSnapshot() async throws -> ConversationSnapshot {
        if let recovery = delivery.recovery {
            await recovery.value
            try Task.checkCancellation()
            if let directory = delivery.directory {
                return directory
            }
        }
        return try await readProviderDirectory().snapshot
    }
}

extension LocalBridgeBackend {
    func readProviderDirectory() async throws
        -> (snapshot: ConversationSnapshot, world: PaginatedWorldResponse) {
        guard let apiClient else {
            throw ChatError.unknown("Conversation refresh requires connect() to complete first.")
        }
        let generation = directoryGeneration
        do {
            var response = try await apiClient.call(.paginatedWorld, WorldRequestLadder.minimumViable.request)
            try Task.checkCancellation()
            guard generation == directoryGeneration, isConnected else { throw CancellationError() }
            reconcileHistoryCutoffs(in: &response)
            reconcileHiddenWorld(in: &response)
            let mapped = WorldMapping.map(response)
            // This request has no verified end-of-directory marker. Absence in
            // its result cannot establish that a cached conversation was removed.
            let removed = Set(response.worldItems.filter { !WorldMapping.isVisible($0) }
                .compactMap { ChannelEventMapping.conversationID($0.groupID) })
            rememberWorldDetails(response)
            let conversations = hydrateMeetingMetadata(in: mapped.conversations).map { row in
                var row = row
                if row.kind == .directMessage, row.members.contains(where: { appMemberIDs.contains($0) }) {
                    row.kind = .appDirectMessage
                }
                return row
            }
            if mapped.skipped > 0 {
                reportResourceFailure(
                    .directoryDetails,
                    error: .decoding("\(mapped.skipped) conversation summaries could not be read.")
                )
            } else {
                resourceRecovered(.directoryDetails)
            }
            requestDirectoryProfiles(for: mapped.conversations, using: apiClient)
            startPresencePoll(using: apiClient, after: memberResolution)
            startCalendarPoll(for: mapped.conversations, after: [memberResolution, selfIdentification])
            return (ConversationSnapshot(
                conversations: conversations, removedIDs: removed, preservesDetails: true
            ), response)
        } catch {
            throw Self.chatError(fromAPI: error)
        }
    }
}

extension LocalBridgeBackend {
    private func rememberWorldDetails(_ response: PaginatedWorldResponse) {
        // Partial directory reads enrich the cache; they do not clear other scopes.
        for item in response.worldItems {
            guard let id = ChannelEventMapping.conversationID(item.groupID) else { continue }
            // Keep explicit hidden/blocked state for management admission.
            conversationDetails[id] = item
            if item.readState.hasLastHeadMessageCreateTimeUsec {
                conversationHeads[id] = max(
                    conversationHeads[id] ?? 0,
                    item.readState.lastHeadMessageCreateTimeUsec
                )
            }
        }
    }
}
