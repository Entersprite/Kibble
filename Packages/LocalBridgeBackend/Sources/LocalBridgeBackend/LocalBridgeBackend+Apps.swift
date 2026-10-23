import ChatKit
import Foundation
import GChatBridgeCore

public extension LocalBridgeBackend {
    func openAppConversation(
        _ app: ChatKit.Member.ID,
        from id: Conversation.ID
    ) async throws -> Conversation {
        let generation = directoryGeneration
        let details = try await conversationDetails(id)
        guard details.membership == .joined, let group = ChannelEventMapping.groupID(for: id),
              let client = apiClient, let me = calendarPoll.me else {
            throw ChatError.unsupported(capability: "conversationApps")
        }
        let apps = try await managementApps(group, generation: generation)
        guard apps.contains(where: { $0.id == app }) else {
            throw ChatError.unsupported(capability: "conversationApp")
        }
        let response = try await client.call(.createBotDm, ChatAppRequests.directMessage(app.rawValue))
        try checkManagementGeneration(generation)
        guard response.hasDm, case let .dmID(dm) = response.dm.groupID.id, !dm.dmID.isEmpty,
              let conversationID = ChannelEventMapping.conversationID(response.dm.groupID),
              response.dm.attributeCheckerGroupType == .oneToOneBotDm else {
            throw unconfirmedManagement()
        }
        let recipients = try await managementApps(response.dm.groupID, generation: generation)
        guard recipients.count == 1, recipients[0].id == app else { throw unconfirmedManagement() }
        let restored = try await restoreDirectConversation(
            Conversation(id: conversationID, kind: .appDirectMessage, members: [me, app]),
            group: response.dm.groupID, using: client, generation: generation
        )
        emit(.membersResolved([recipients[0].member]))
        emit(.conversationUpdated(restored))
        return restored
    }

    func searchConversationApps(_ query: String, in id: Conversation.ID) async throws -> [ConversationApp] {
        let generation = directoryGeneration
        let details = try await conversationDetails(id)
        guard details.membership == .joined, details.allowedActions.contains("addApp"),
              query.utf16.count <= 256,
              let group = ChannelEventMapping.groupID(for: id) else {
            throw ChatError.unsupported(capability: "conversationApps")
        }
        let installed = try await Set(managementApps(group, generation: generation).map(\.id))
        let payload = try await conversationRPCPayload(ChatAppRequests.search(query))
        try checkManagementGeneration(generation)
        let decoded = try PBLiteDecoder.decode(SearchChatAppsResponse.self, from: payload)
        guard decoded.issues.allSatisfy({ $0.kind == .unknownField }),
              decoded.message.users.count <= 100 else {
            throw ChatError.decoding("The app directory returned an unsupported response.")
        }
        var seen = Set<ChatKit.Member.ID>()
        return decoded.message.users.compactMap { row in
            guard row.hasID, row.id.kind == 1, !row.id.rawID.isEmpty else { return nil }
            let member = ChatKit.Member(
                id: .init(row.id.rawID), kind: .app,
                displayName: row.name.isEmpty ? nil : row.name,
                email: row.email.isEmpty ? nil : row.email,
                avatarURL: row.avatarURL.isEmpty ? nil : URL(string: row.avatarURL)
            )
            guard !installed.contains(member.id), seen.insert(member.id).inserted else { return nil }
            return ConversationApp(
                member: member, description: row.appInfo.hasDescription_p ? row.appInfo.description_p : nil,
                allowedActions: ["addApp"]
            )
        }
    }
}

extension LocalBridgeBackend {
    func managementApps(_ group: GroupId, generation: Int) async throws -> [ConversationApp] {
        guard let client = apiClient else { throw ChatError.notAuthenticated }
        var ids: [MemberId] = []
        var token: String?
        var seen = Set<String>()
        for _ in 0 ..< 10 {
            let response = try await client.call(.listMembers, ChatAppRequests.list(group, token: token))
            try checkManagementGeneration(generation)
            for row in response.memberships {
                guard row.hasID, row.id.groupID == group else { throw unconfirmedManagement() }
                guard row.id.memberID.userID.type == .bot,
                      !row.id.memberID.userID.id.isEmpty else { continue }
                guard row.membershipState == .memberJoined || row.membershipState == .memberInvited
                else { continue }
                if !ids.contains(row.id.memberID) {
                    ids.append(row.id.memberID)
                }
            }
            guard ids.count <= 512 else { throw ChatError.decoding("The app list is too large.") }
            if response.nextPageToken.isEmpty {
                return try await managementAppProfiles(
                    ids,
                    generation: generation
                )
            }
            guard seen.insert(response.nextPageToken).inserted else { throw unconfirmedManagement() }
            token = response.nextPageToken
        }
        throw ChatError.decoding("The app list could not be completed.")
    }

    private func managementAppProfiles(_ ids: [MemberId], generation: Int) async throws -> [ConversationApp] {
        guard let client = apiClient else { throw ChatError.notAuthenticated }
        var result: [ConversationApp] = []
        for offset in stride(from: 0, to: ids.count, by: 100) {
            let chunk = Array(ids[offset ..< min(offset + 100, ids.count)])
            var request = GetMembersRequest()
            request.requestHeader = APIRequestHeader.make()
            request.memberIds = chunk
            let response = try await client.call(.getMembers, request)
            try checkManagementGeneration(generation)
            let profiles = MemberMapping.map(response).members
            result += chunk.map { id in
                let member = profiles.first { $0.id.rawValue == id.userID.id && $0.kind == .app }
                    ?? ChatKit.Member(id: .init(id.userID.id), kind: .app)
                let info = response.members.first { $0.user.userID == id.userID }?.user.botInfo
                return ConversationApp(
                    member: member,
                    description: info?.hasDescription_p == true ? info?.description_p : nil
                )
            }
        }
        return result
    }

    func applyAppWrite(_ mutation: ConversationMutation, context: ManagementWriteContext) async throws {
        switch mutation {
        case let .addApp(id):
            guard !id.rawValue.isEmpty, id.rawValue.utf16.count <= 256 else {
                throw ChatError.unsupported(capability: "conversationApp")
            }
            var request = GetMembersRequest()
            request.requestHeader = APIRequestHeader.make()
            request.memberIds = [ChatAppRequests.member(id.rawValue)]
            let profile = try await context.client.call(.getMembers, request)
            try checkManagementGeneration(context.generation)
            guard profile.members.contains(where: {
                $0.user.userID.id == id.rawValue && $0.user.userID.type == .bot
            }) else { throw ChatError.unsupported(capability: "conversationApp") }
            let response = try await context.client.call(
                .createMembership, ChatAppRequests.add(id.rawValue, to: context.group)
            )
            try checkManagementGeneration(context.generation)
            guard response.results.contains(where: {
                (!$0.hasReason || $0.reason == 0) && $0.hasMembership
                    && $0.membership.id.groupID == context.group
                    && $0.membership.id.memberID == ChatAppRequests.member(id.rawValue)
                    && [.memberJoined, .memberInvited].contains($0.membership.membershipState)
            }) else { throw unconfirmedManagement() }
        case let .removeApp(id):
            let installed = try await managementApps(context.group, generation: context.generation)
            guard installed.contains(where: { $0.id == id }) else { throw unconfirmedManagement() }
            let member = ChatAppRequests.member(id.rawValue)
            let response = try await context.client.call(
                .removeMemberships, ConversationActionRequests.leave(group: context.group, member: member)
            )
            try checkManagementGeneration(context.generation)
            guard response.results.contains(where: {
                $0.memberID == member && (!$0.hasReason || $0.reason == 0)
            }) else { throw unconfirmedManagement() }
        default: throw ChatError.unsupported(capability: "conversationApps")
        }
    }
}
