import ChatKit
import Foundation

extension FakeBackend {
    func applyManagement(
        _ mutation: ConversationMutation,
        details: inout ConversationDetails,
        participants: inout [ConversationParticipant]
    ) throws -> [Member.ID] {
        if try applyManagedSettings(mutation, details: &details) {
            return []
        }
        if try applyManagedIntegrations(mutation, details: details) {
            return []
        }
        var failed: [Member.ID] = []
        switch mutation {
        case let .addPeople(ids):
            failed = addManagedPeople(ids, participants: &participants)
        case let .setPersonBlocked(id, blocked):
            try setManagedPersonBlocked(id, blocked: blocked, participants: &participants)
        case .removePerson, .setRole:
            try changeManagedParticipant(mutation, participants: &participants)
        case .join, .acceptInvitation, .requestJoin, .declineInvitation, .block:
            setManagedMembership(mutation, details: &details, participants: &participants)
        case .approveRequest, .rejectRequest:
            try changeManagedRequest(mutation, participants: &participants)
        case .leave, .deleteSpace:
            try removeManagedConversation(mutation, details: &details)
        default:
            throw ChatError.unsupported(capability: "conversationMutation")
        }
        if details.membership == .joined {
            details.conversation.members = participants.filter { $0.state == .joined }.map(\.id)
            details.conversation.memberCount = details.conversation.members.count
        }
        return failed
    }

    private func changeManagedRequest(
        _ mutation: ConversationMutation, participants: inout [ConversationParticipant]
    ) throws {
        switch mutation {
        case let .approveRequest(id):
            try approveManagedRequest(id, participants: &participants)
        case let .rejectRequest(id):
            participants.removeAll { $0.id == id && $0.state == .requested }
        default: throw ChatError.unsupported(capability: mutation.action)
        }
    }

    private func setManagedPersonBlocked(
        _ id: Member.ID, blocked: Bool, participants: inout [ConversationParticipant]
    ) throws {
        try require(capabilities.canBlockConversations, "canBlockConversations")
        guard id != world.me, let index = participants.firstIndex(where: { $0.id == id }),
              participants[index].member.kind == .human else {
            throw ChatError.unsupported(capability: "blockPerson")
        }
        if blocked {
            blockedDirectMembers.insert(id)
        } else {
            blockedDirectMembers.remove(id)
        }
        participants[index].isBlocked = blocked
    }

    private func applyManagedSettings(
        _ mutation: ConversationMutation,
        details: inout ConversationDetails
    ) throws -> Bool {
        switch mutation {
        case let .convertToSpace(name, emoji, acknowledged):
            try convertManagedChat(name: name, emoji: emoji, acknowledged: acknowledged, details: &details)
        case let .settings(patch):
            try changeManagedSettings(patch, details: &details)
        case let .emoji(value):
            guard value.count <= 1, details.settings != nil else {
                throw ChatError.unsupported(capability: "conversationEmoji")
            }
            details.settings?.emoji = value
        case let .identity(name, description, access):
            guard access == nil else { throw ChatError.unsupported(capability: "identityAccess") }
            try changeManagedDetails(.init(name: name, description: description), details: &details)
        case let .details(patch):
            try changeManagedDetails(patch, details: &details)
        case let .guidelines(value):
            try changeManagedDetails(.init(guidelines: value), details: &details)
        default: return false
        }
        return true
    }

    private func applyManagedIntegrations(
        _ mutation: ConversationMutation,
        details: ConversationDetails
    ) throws -> Bool {
        switch mutation {
        case .generateEmail, .setEmailDelivery, .deleteEmail:
            try changeManagedEmail(mutation, in: details.conversation.id)
        case .addApp, .removeApp:
            try changeManagedApps(mutation, in: details.conversation.id)
        case .saveWebhook, .deleteWebhook:
            try changeManagedWebhooks(mutation, in: details.conversation.id)
        default: return false
        }
        return true
    }

    private func convertManagedChat(
        name: String,
        emoji: String?,
        acknowledged: Bool,
        details: inout ConversationDetails
    ) throws {
        guard acknowledged, details.conversation.kind == .groupDirectMessage,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf16.count <= 128, emoji == nil || (emoji?.count ?? 0) <= 1 else {
            throw ChatError.unsupported(capability: "convertToSpace")
        }
        details.conversation.kind = .space
        details.conversation.title = name
        details.access = .restricted; details.settings = Self.ownerSettings
        details.settings?.emoji = emoji
        details.allowedActions = Self.ownerActions
    }

    private func changeManagedDetails(
        _ patch: ConversationDetailsPatch,
        details: inout ConversationDetails
    ) throws {
        guard patch.name != nil || patch.description != nil || patch.guidelines != nil || patch
            .emoji != nil,
            patch.name == nil || details.allowedActions.contains("rename"),
            patch.description == nil || details.allowedActions.contains("description"),
            patch.guidelines == nil || details.allowedActions.contains("guidelines"),
            patch.emoji == nil || details.allowedActions.contains("emoji"),
            patch.name == nil || details.conversation.kind != .space
            || !(patch.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            (patch.name?.utf16.count ?? 0) <= 128, (patch.description?.utf16.count ?? 0) <= 150,
            (patch.guidelines?.utf16.count ?? 0) <= 5000, (patch.emoji?.count ?? 0) <= 1 else {
            throw ChatError.unsupported(capability: "detailsFields")
        }
        setManagedIdentity(
            name: patch.name,
            description: patch.description,
            access: nil,
            details: &details
        )
        if let guidelines = patch.guidelines {
            details.guidelines = guidelines
        }
        if let emoji = patch.emoji {
            details.settings?.emoji = emoji
        }
    }

    private func changeManagedSettings(
        _ patch: ConversationSettingsPatch, details: inout ConversationDetails
    ) throws {
        guard var settings = details.settings,
              patch.access == nil || settings.canChangeAccess,
              patch.requestToJoin == nil || settings.canChangeRequestToJoin else {
            throw ChatError.unsupported(capability: "conversationSettings")
        }
        try validateManagedVisibility(patch.permissions, current: settings.permissions)
        for (id, audience) in patch.permissions {
            guard let index = settings.permissions.firstIndex(where: { $0.id == id && $0.isEditable }),
                  [.owners, .managers, .members, .organization].contains(audience),
                  audience != .organization || id == "viewMembers" else {
                throw ChatError.unsupported(capability: "conversationPermission")
            }
            settings.permissions[index].audience = audience
        }
        if let access = patch.access {
            guard [.restricted, .discoverable, .open].contains(access) else {
                throw ChatError.unsupported(capability: "conversationAccess")
            }
            details.access = access
        }
        if let request = patch.requestToJoin {
            settings.requestToJoin = request
        }
        guard details.access != .open || settings.requestToJoin != true else {
            throw ChatError.unsupported(capability: "requestToJoin")
        }
        details.settings = settings
    }

    private func validateManagedVisibility(
        _ changes: [String: PermissionAudience], current: [ConversationPermission]
    ) throws {
        guard changes["viewMembers"] != nil || changes["manageMembers"] != nil else { return }
        let levels: [PermissionAudience] = [.owners, .managers, .members, .organization]
        let view = changes["viewMembers"] ?? current.first { $0.id == "viewMembers" }?.audience
        let manage = changes["manageMembers"] ?? current.first { $0.id == "manageMembers" }?.audience
        guard let view, let manage, let viewLevel = levels.firstIndex(of: view),
              let manageLevel = levels.firstIndex(of: manage), manageLevel <= viewLevel else {
            throw ChatError.unknown("People who manage members must be able to view them.")
        }
    }

    private func removeManagedConversation(
        _ mutation: ConversationMutation,
        details: inout ConversationDetails
    ) throws {
        if mutation == .deleteSpace, details.conversation.kind != .space {
            throw ChatError.unsupported(capability: "deleteSpace")
        }
        details.membership = .unknown
        details.allowedActions = []
        world.conversations.removeAll { $0.id == details.conversation.id }
        emit(.conversationRemoved(conversationID: details.conversation.id, historyBefore: nil))
    }

    private func approveManagedRequest(
        _ id: Member.ID,
        participants: inout [ConversationParticipant]
    ) throws {
        guard let index = participants.firstIndex(where: { $0.id == id && $0.state == .requested }) else {
            throw ChatError.unknown("This request is no longer pending.")
        }
        participants[index].state = .joined
    }

    private func setManagedIdentity(
        name: String?,
        description: String?,
        access: ConversationAccess?,
        details: inout ConversationDetails
    ) {
        if let name {
            details.conversation.title = name
        }
        if let description {
            details.description = description
        }
        if let access {
            details.access = access
        }
    }

    private func setManagedMembership(
        _ mutation: ConversationMutation,
        details: inout ConversationDetails,
        participants: inout [ConversationParticipant]
    ) {
        switch mutation {
        case .join, .acceptInvitation:
            details.membership = .joined
            if world.conversation(details.conversation.id) == nil {
                details.conversation.members = [world.me]
                world.conversations.append(details.conversation)
            }
            details.allowedActions = ["leave", "addPeople"]
            if !participants.contains(where: { $0.id == world.me }) {
                let member = world.member(world.me) ?? Member(id: world.me, kind: .human)
                participants.append(ConversationParticipant(member: member, role: .member, state: .joined))
            }
        case .requestJoin:
            details.membership = .requested
            details.allowedActions = []
        default:
            details.membership = .unknown
            details.allowedActions = []
        }
    }

    private func addManagedPeople(
        _ ids: [Member.ID],
        participants: inout [ConversationParticipant]
    ) -> [Member.ID] {
        var failed: [Member.ID] = []
        let known = Dictionary(
            (world.members + directory).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for id in Set(ids).sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let member = known[id] else { failed.append(id); continue }
            guard !participants.contains(where: { $0.id == id }) else { continue }
            participants.append(ConversationParticipant(
                member: member,
                role: .member,
                state: .joined,
                allowedActions: ["removePerson", "setRole"],
                allowedRoles: [
                    .member,
                    .manager,
                    .owner
                ]
            ))
            if world.member(id) == nil {
                world.members.append(member)
            }
            emit(.membersResolved([member]))
        }
        return failed
    }

    private func changeManagedParticipant(
        _ mutation: ConversationMutation,
        participants: inout [ConversationParticipant]
    ) throws {
        switch mutation {
        case let .removePerson(id):
            guard let row = participants.first(where: { $0.id == id }),
                  row.allowedActions.contains("removePerson")
            else { throw ChatError.unknown("This person cannot be removed.") }
            guard row.role != .owner || participants.filter({ $0.role == .owner && $0.state == .joined })
                .count > 1 else {
                throw ChatError.unknown("Choose another owner before removing the last owner.")
            }
            participants.removeAll { $0.id == id }
        case let .setRole(id, role):
            guard [.member, .manager, .owner].contains(role),
                  let index = participants.firstIndex(where: { $0.id == id }),
                  participants[index].allowedActions.contains("setRole"),
                  participants[index].allowedRoles.contains(role) else {
                throw ChatError.unknown("This role change is unavailable.")
            }
            guard participants[index].role != .owner || role == .owner
                || participants.filter({ $0.role == .owner && $0.state == .joined }).count > 1 else {
                throw ChatError.unknown("Choose another owner first.")
            }
            participants[index].role = role
        default: break
        }
    }
}
