import ChatKit
import GChatBridgeCore

public extension LocalBridgeBackend {
    func blockedPeople() async throws -> [BlockedPerson] {
        let generation = try await blockedListGeneration()
        guard let apiClient else { throw ChatError.notAuthenticated }
        let users = try await readBlockedUsers(using: apiClient, generation: generation)
        return try await blockedPersonRows(users, using: apiClient, generation: generation)
    }

    func unblockPerson(_ id: ChatKit.Member.ID) async throws -> [BlockedPerson] {
        guard unblockingPeople.insert(id).inserted else {
            throw ChatError.unknown("This person is already being unblocked.")
        }
        defer { unblockingPeople.remove(id) }
        let generation = try await blockedListGeneration()
        guard let apiClient else { throw ChatError.notAuthenticated }
        let users = try await readBlockedUsers(using: apiClient, generation: generation)
        guard let user = users.first(where: { $0.id == id.rawValue }) else {
            return try await blockedPersonRows(users, using: apiClient, generation: generation)
        }
        var target = UserId()
        target.id = user.id
        if user.hasType {
            target.type = user.type
        }
        let failure: ChatError?
        do {
            _ = try await apiClient.call(
                .blockEntity,
                ConversationActionRequests.block(user: target, blocked: false)
            )
            failure = nil
        } catch {
            failure = Self.chatError(fromAPI: error, call: "unblocking a person")
        }
        try checkManagementGeneration(generation)
        let confirmed = try await readBlockedUsers(using: apiClient, generation: generation)
        guard !confirmed.contains(where: { $0.id == id.rawValue }) else {
            throw failure ?? ChatError.decoding("The service did not confirm the unblock.")
        }
        return try await blockedPersonRows(confirmed, using: apiClient, generation: generation)
    }
}

private extension LocalBridgeBackend {
    func readBlockedUsers(using client: ProtoAPIClient, generation: Int) async throws -> [UserId] {
        let response: ListBlockedUsersResponse
        do {
            response = try await client.call(.listBlockedUsers, ConversationActionRequests.blockedUsers())
        } catch {
            throw Self.chatError(fromAPI: error, call: "loading blocked people")
        }
        try checkManagementGeneration(generation)
        let users = response.blockedUserID
        let ids = users.map(\.id)
        guard ids.count <= 4096, Set(ids).count == ids.count,
              ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }) else {
            throw ChatError.decoding("The service returned an invalid blocked-people list.")
        }
        return users
    }

    func blockedPersonRows(
        _ users: [UserId], using client: ProtoAPIClient, generation: Int
    ) async throws -> [BlockedPerson] {
        let ids = users.map { ChatKit.Member.ID($0.id) }
        var names: [ChatKit.Member.ID: String] = [:]
        for offset in stride(from: 0, to: ids.count, by: 100) {
            let batch = Array(ids[offset ..< min(offset + 100, ids.count)])
            let requested = Set(batch)
            let reply = try? await client.call(.getMembers, Self.getMembersRequest(batch))
            try checkManagementGeneration(generation)
            guard let reply else { break }
            for member in MemberMapping.map(reply).members where requested.contains(member.id) {
                if let name = member.displayName, name.utf8.count <= 4096 {
                    names[member.id] = name
                }
            }
        }
        return ids.map { BlockedPerson(id: $0, name: names[$0] ?? "") }
    }
}
