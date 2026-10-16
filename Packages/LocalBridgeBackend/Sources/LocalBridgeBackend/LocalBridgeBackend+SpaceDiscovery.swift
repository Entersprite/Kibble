import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeBackend {
    func discoverManagementSpaces(
        _ query: SpaceDirectoryQuery, token: String?, key: String, generation: Int, client: ProtoAPIClient
    ) async throws -> SpaceDirectoryPage {
        let result = try await spaceDirectoryReader(client: client, generation: generation)
            .discover(
                query.text,
                token: token,
                key: key,
                scope: query.scope,
                organization: query.organization
            )
        try checkManagementGeneration(generation)
        discoverableManagementSpaces.formUnion(result.spaces.filter {
            $0.membership != .joined && $0.membership != .invited
        }.map(\.conversation.id))
        return result
    }

    func directorySpace(
        _ group: GroupId, generation: Int, client: ProtoAPIClient
    ) async throws -> ConversationDetails? {
        try await spaceDirectoryReader(client: client, generation: generation).space(group)
    }

    private func spaceDirectoryReader(client: ProtoAPIClient, generation: Int) -> SpaceDirectoryReader {
        SpaceDirectoryReader(
            client: client,
            known: conversationDetails.compactMapValues(WorldMapping.conversation),
            check: { try await self.checkManagementGeneration(generation) }
        )
    }
}
