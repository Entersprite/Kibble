import ChatKit
import Foundation

public extension FakeBackend {
    func createConversation(_ draft: ConversationDraft) async throws -> ConversationCreationResult {
        try requireConnected()
        try require(capabilities.canCreateConversations, "canCreateConversations")
        guard draft.kind == .groupDirectMessage || draft.kind == .space else {
            throw ChatError.unknown("Choose a group chat or space.")
        }
        guard draft.kind != .space || !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ChatError.unknown("Enter a space name.")
        }
        let people = Array(Set(draft.members)).filter { $0 != world.me }.sorted { $0.rawValue < $1.rawValue }
        guard draft.kind != .groupDirectMessage || people.count >= 2 else {
            throw ChatError.unknown("Choose at least two other people.")
        }
        let known = Dictionary(
            (world.members + directory).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let accepted = people.filter { known[$0] != nil }
        let conversation = Conversation(
            id: Conversation.ID(nextIdentifier("fixture-conversation")), kind: draft.kind,
            title: draft.name.isEmpty ? nil : draft.name, members: [world.me] + accepted,
            memberCount: accepted.count + 1, repliesEnabled: true
        )
        world.conversations.append(conversation)
        for member in accepted.compactMap({ known[$0] }) where world.member(member.id) == nil {
            world.members.append(member)
        }
        managedDetails[conversation.id] = ConversationDetails(
            conversation: conversation, description: draft.description, access: draft.access,
            membership: .joined,
            allowedActions: draft.kind == .space ? Self.ownerActions : Self.ownerActions
                .subtracting(["deleteSpace"]), revision: nextIdentifier("revision")
        )
        emit(.conversationUpdated(conversation))
        emit(.membersResolved(accepted.compactMap { known[$0] }))
        return ConversationCreationResult(
            conversation: conversation,
            failedMembers: people.filter { known[$0] == nil }
        )
    }

    func conversationDetails(_ id: Conversation.ID) async throws -> ConversationDetails {
        try requireConnected()
        try require(capabilities.canReadConversationDetails, "canReadConversationDetails")
        if let details = managedDetails[id] {
            return details
        }
        guard let conversation = world.conversation(id) else {
            throw ChatError.unknown("This conversation is unavailable.")
        }
        let manageable = conversation.kind == .space || conversation.kind == .groupDirectMessage
        let details = ConversationDetails(
            conversation: conversation,
            membership: .joined,
            allowedActions: manageable ? Self.ownerActions
                .subtracting(conversation.kind == .space ? [] : ["deleteSpace"]) : []
        )
        managedDetails[id] = details
        return details
    }

    func participants(
        in id: Conversation.ID,
        after cursor: String?
    ) async throws -> ConversationParticipantPage {
        let details = try await conversationDetails(id)
        let rows = managedParticipants[id] ?? world.members(in: details.conversation).map {
            ConversationParticipant(
                member: $0,
                role: $0.id == world.me ? .owner : .member,
                state: .joined,
                allowedActions: $0.id == world.me ? [] : [
                    "removePerson",
                    "setRole"
                ],
                allowedRoles: $0.id == world.me ? [] : [.member, .manager, .owner]
            )
        }
        let offset = try managementOffset(cursor, key: "members:\(id.rawValue)")
        let end = min(rows.count, offset + min(max(1, pageSize), max(0, rows.count - offset)))
        return ConversationParticipantPage(
            participants: offset < rows.count ? Array(rows[offset ..< end]) : [],
            nextCursor: end < rows.count ? "members:\(id.rawValue)|\(end)" : nil
        )
    }

    func browseSpaces(
        _ query: SpaceDirectoryQuery,
        after cursor: String?
    ) async throws -> SpaceDirectoryPage {
        try requireConnected()
        try require(capabilities.canBrowseSpaces, "canBrowseSpaces")
        var spaces = try await directorySpaces(query.scope)
        if query.organization == .internalOnly {
            spaces.removeAll { $0.conversation.id == .init("fixture-external-space") }
        } else if query.organization == .externalOnly {
            spaces = spaces.filter { $0.conversation.id == .init("fixture-external-space") }
        } else if query.organization != .all {
            throw ChatError.unsupported(capability: "spaceDirectoryOrganization")
        }
        spaces = spaces.filter {
            query.text.isEmpty || ($0.conversation.title ?? "").localizedCaseInsensitiveContains(query.text)
                || ($0.description ?? "").localizedCaseInsensitiveContains(query.text)
        }.sorted { ($0.conversation.title ?? "") < ($1.conversation.title ?? "") }
        let key = "spaces:\(query.scope.type):\(query.organization.type):\(query.text)"
        let offset = try managementOffset(cursor, key: key)
        let end = min(spaces.count, offset + min(max(1, pageSize), max(0, spaces.count - offset)))
        return SpaceDirectoryPage(
            spaces: offset < spaces.count ? Array(spaces[offset ..< end]) : [],
            nextCursor: end < spaces.count ? "\(key)|\(end)" : nil
        )
    }

    func mutateConversation(
        _ mutation: ConversationMutation,
        in id: Conversation.ID,
        operationID: String,
        expectedRevision: String?
    ) async throws -> ConversationMutationResult {
        try requireConnected()
        if let completed = completedMutations[operationID] {
            guard completed.conversation == id, completed.mutation == mutation else {
                throw ChatError.unknown("This operation identifier has already been used.")
            }
            return completed.result
        }
        var details = try await conversationDetails(id)
        guard details.allowedActions.contains(mutation.action) else {
            throw ChatError.unknown("You do not have permission to make this change.")
        }
        guard expectedRevision == nil || details.revision == expectedRevision else {
            throw ChatError.unknown("This conversation changed. Reload it before saving.")
        }
        var rows = managedParticipants[id] ?? world.members(in: details.conversation).map {
            ConversationParticipant(
                member: $0,
                role: $0.id == world.me ? .owner : .member,
                state: .joined,
                allowedActions: $0.id == world.me ? [] : ["removePerson", "setRole"],
                allowedRoles: $0.id == world.me ? [] : [.member, .manager, .owner]
            )
        }
        let failed = try applyManagement(mutation, details: &details, participants: &rows)
        details.revision = nextIdentifier("revision")
        managedDetails[id] = details
        managedParticipants[id] = rows
        if let index = world.conversations.firstIndex(where: { $0.id == id }) {
            world.conversations[index] = details.conversation
            emit(.conversationUpdated(details.conversation))
        }
        let result = ConversationMutationResult(
            operationID: operationID,
            details: details,
            failedMembers: failed
        )
        completedMutations[operationID] = FixtureManagementOperation(
            conversation: id,
            mutation: mutation,
            result: result
        )
        return result
    }
}

extension FakeBackend {
    private func directorySpaces(_ scope: SpaceDirectoryScope) async throws -> [ConversationDetails] {
        if scope == .joined {
            return try await world.conversations.filter { $0.kind == .space }.asyncDetails(using: self)
        }
        if scope == .all {
            let joined = try await directorySpaces(.joined)
            return try await joined + directorySpaces(.discover)
        }
        if scope == .invitations || scope == .spamInvitations {
            return directoryInvitation(spam: scope == .spamInvitations)
        }
        guard scope == .discover else { throw ChatError.unsupported(capability: "spaceDirectoryScope") }
        var spaces = requestableManagementSpaces() + directoryInvitation(spam: false)
        for (id, title) in [
            ("fixture-discoverable-space", "Coffee Break"),
            ("fixture-external-space", "Partner Planning")
        ] {
            let id = Conversation.ID(id)
            let details = managedDetails[id] ?? ConversationDetails(
                conversation: Conversation(id: id, kind: .space, title: title, memberCount: 7),
                description: "A place for everyone to catch up.", access: .open,
                allowedActions: ["join"]
            )
            managedDetails[id] = details
            if world.conversation(id) == nil, !details.allowedActions.isEmpty {
                spaces.append(details)
            }
        }
        return spaces
    }

    private func directoryInvitation(spam: Bool) -> [ConversationDetails] {
        let id = Conversation.ID(spam ? "fixture-spam-space" : "fixture-invited-space")
        let details = managedDetails[id] ?? ConversationDetails(
            conversation: Conversation(
                id: id,
                kind: .space,
                title: spam ? "Unrecognized Invitation" : "Design Review"
            ),
            description: spam ? "An invitation marked as spam." : "You have been invited to join.",
            access: .restricted, membership: .invited,
            allowedActions: ["acceptInvitation", "declineInvitation"]
        )
        managedDetails[id] = details
        return world.conversation(id) == nil && !details.allowedActions.isEmpty ? [details] : []
    }

    static let ownerActions: Set<String> = [
        "leave", "identity", "rename", "description", "addPeople", "removePerson", "setRole",
        "approveRequest",
        "rejectRequest",
        "deleteSpace"
    ]

    private func requestableManagementSpaces() -> [ConversationDetails] {
        let id = Conversation.ID("fixture-requestable-space")
        guard world.conversation(id) == nil else { return [] }
        let details = managedDetails[id] ?? ConversationDetails(
            conversation: Conversation(id: id, kind: .space, title: "Project Reviews"),
            description: "Request access to project discussions.", access: .discoverable,
            allowedActions: ["requestJoin"]
        )
        managedDetails[id] = details
        return details.membership == .requested || !details.allowedActions.isEmpty ? [details] : []
    }

    private func managementOffset(_ cursor: String?, key: String) throws -> Int {
        guard let cursor else { return 0 }
        let prefix = key + "|"
        guard cursor.hasPrefix(prefix), let offset = Int(cursor.dropFirst(prefix.count)), offset >= 0 else {
            throw ChatError.unknown("This page has expired. Search again.")
        }
        return offset
    }
}

private extension [Conversation] {
    func asyncDetails(using backend: FakeBackend) async throws -> [ConversationDetails] {
        var details: [ConversationDetails] = []
        for conversation in self {
            try await details.append(backend.conversationDetails(conversation.id))
        }
        return details
    }
}

struct FixtureManagementOperation {
    var conversation: Conversation.ID
    var mutation: ConversationMutation
    var result: ConversationMutationResult
}
