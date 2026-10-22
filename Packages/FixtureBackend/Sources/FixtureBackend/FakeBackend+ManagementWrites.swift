import ChatKit
import Foundation

extension FakeBackend {
    func applyManagement(
        _ mutation: ConversationMutation,
        details: inout ConversationDetails,
        participants: inout [ConversationParticipant]
    ) throws -> [Member.ID] {
        var failed: [Member.ID] = []
        switch mutation {
        case let .identity(name, description, access):
            setManagedIdentity(name: name, description: description, access: access, details: &details)
        case let .addPeople(ids):
            failed = addManagedPeople(ids, participants: &participants)
        case .removePerson, .setRole:
            try changeManagedParticipant(mutation, participants: &participants)
        case .join, .acceptInvitation, .requestJoin, .declineInvitation, .block:
            setManagedMembership(mutation, details: &details, participants: &participants)
        case let .approveRequest(id):
            try approveManagedRequest(id, participants: &participants)
        case let .rejectRequest(id):
            participants.removeAll { $0.id == id && $0.state == .requested }
        case .leave, .deleteSpace:
            try removeManagedConversation(mutation, details: &details)
        case .unknown:
            throw ChatError.unsupported(capability: "conversationMutation")
        }
        if details.membership == .joined {
            details.conversation.members = participants.filter { $0.state == .joined }.map(\.id)
            details.conversation.memberCount = details.conversation.members.count
        }
        return failed
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
            guard row.role != .owner || participants.filter({ $0.role == .owner }).count > 1 else {
                throw ChatError.unknown("Choose another owner before removing the last owner.")
            }
            participants.removeAll { $0.id == id }
        case let .setRole(id, role):
            guard [.member, .manager, .owner].contains(role),
                  let index = participants.firstIndex(where: { $0.id == id }),
                  participants[index].allowedActions.contains("setRole") else {
                throw ChatError.unknown("This role change is unavailable.")
            }
            guard participants[index].role != .owner || role == .owner
                || participants.filter({ $0.role == .owner }).count > 1 else {
                throw ChatError.unknown("Choose another owner first.")
            }
            participants[index].role = role
        default: break
        }
    }
}
