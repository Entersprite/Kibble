import ChatKit
import Foundation
import GChatBridgeCore

/// A space's members, for the composer's `@` list (mention composer spec §3.2).
///
/// The world names the members of DMs and group chats and nobody else
/// (`findings.md` §43.1), so this is a no-op for a `dm/` conversation. For a
/// space: `list_members`, then one `get_members` for names and emails, then
/// `.membersChanged`.
extension LocalBridgeBackend {
    static let memberPageLimit = 10

    func loadMembers(_ conversationID: Conversation.ID) async throws {
        guard let apiClient else {
            throw ChatError.unknown("loadMembers requires connect() to succeed first")
        }
        guard let group = ChannelEventMapping.groupID(for: conversationID) else {
            throw ChatError.unknown(
                "\(conversationID.rawValue) has neither the space/ nor the dm/ prefix this backend produces"
            )
        }
        guard case .spaceID = group.id else { return }
        let generation = directoryGeneration
        let (ids, truncated) = try await joinedMemberIDs(of: group, using: apiClient)
        // Last, on every way out: `.membersChanged` supersedes the last error
        // (`SyncReducer.supersedingStaleError`), so an error emitted before
        // it was erased at once (CLAUDE.md, session 34; review finding 4).
        defer {
            if truncated, generation == directoryGeneration {
                emit(.backendError(.unknown(
                    "list_members answered more than \(Self.memberPageLimit) pages; only the first "
                        + "\(Self.memberPageLimit) are kept"
                )))
            }
        }
        guard !ids.isEmpty else { return }

        let response: GetMembersResponse
        do {
            response = try await apiClient.call(.getMembers, Self.getMembersRequest(ids))
        } catch {
            throw Self.chatError(fromAPI: error, call: "the /api/ get_members call")
        }
        // After the awaits: a session that ended meanwhile must not write
        // into the next one.
        guard generation == directoryGeneration else { return }
        let mapped = MemberMapping.map(response)
        remember(emailsOf: mapped.members)
        let byID = Dictionary(mapped.members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // In list order. An id `get_members` does not return is left out, the
        // rule `resolveAndEmitMembers` follows.
        let members = ids.compactMap { byID[$0] }
        guard !members.isEmpty else { return }
        emit(.membersChanged(conversationID: conversationID, members: members))
    }

    /// Every joined member over at most `memberPageLimit` pages, and whether
    /// the server had more.
    private func joinedMemberIDs(
        of group: GroupId,
        using apiClient: ProtoAPIClient
    ) async throws -> (ids: [ChatKit.Member.ID], truncated: Bool) {
        var ids: [ChatKit.Member.ID] = []
        var token: String?
        var pages = 0
        repeat {
            let response: ListMembersResponse
            do {
                response = try await apiClient.call(
                    .listMembers, MembersRequests.listMembers(group: group, pageToken: token)
                )
            } catch {
                throw Self.chatError(fromAPI: error, call: "the /api/ list_members call")
            }
            ids += Self.joinedMemberIDs(response)
            pages += 1
            token = response.nextPageToken.isEmpty ? nil : response.nextPageToken
        } while token != nil && pages < Self.memberPageLimit
        return (ids, token != nil)
    }

    /// Joined members only: an invitee cannot see the message (§56.1).
    static func joinedMemberIDs(_ response: ListMembersResponse) -> [ChatKit.Member.ID] {
        response.memberships.compactMap { membership in
            guard membership.membershipState == .memberJoined else { return nil }
            let id = membership.id.memberID.userID.id
            return id.isEmpty ? nil : ChatKit.Member.ID(id)
        }
    }

    func remember(emailsOf members: [ChatKit.Member]) {
        for member in members {
            if let email = member.email, !email.isEmpty {
                memberEmails[member.id] = email
            }
        }
    }
}
