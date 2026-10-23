import ChatKit

extension FakeBackend {
    func refreshedManagedParticipants(_ values: [ConversationParticipant]) -> [ConversationParticipant] {
        var rows = values
        let viewerIsOwner = rows.contains { $0.id == world.me && $0.role == .owner && $0.state == .joined }
        let hasOtherOwner = rows.contains { $0.id != world.me && $0.role == .owner && $0.state == .joined }
        for index in rows.indices {
            let person = rows[index].id
            if person == world.me {
                rows[index].allowedActions.remove("setRole")
                rows[index].allowedRoles = []
            }
            if person == world.me, rows[index].role == .owner, hasOtherOwner {
                rows[index].allowedActions.insert("setRole"); rows[index].allowedRoles = [
                    .member,
                    .manager,
                    .owner
                ]
            }
            if person != world.me, rows[index].state == .joined {
                rows[index].allowedRoles = viewerIsOwner ? [.member, .manager, .owner]
                    : rows[index].role == .owner ? [] : [.member, .manager]
                if rows[index].allowedRoles.isEmpty {
                    rows[index].allowedActions.remove("setRole")
                } else {
                    rows[index].allowedActions.insert("setRole")
                }
                if rows[index].role == .owner, !viewerIsOwner {
                    rows[index].allowedActions.remove("removePerson")
                }
            }
            if person != world.me, rows[index].member.kind == .human {
                rows[index].isBlocked = blockedDirectMembers.contains(person)
                rows[index].allowedActions.subtract(["blockPerson", "unblockPerson"])
                if capabilities.canBlockConversations {
                    rows[index].allowedActions
                        .insert(blockedDirectMembers.contains(person) ? "unblockPerson" : "blockPerson")
                }
            }
        }
        return rows
    }

    func supportedManagedDetails(_ supplied: ConversationDetails) -> ConversationDetails {
        var details = supplied
        let flags: [(Bool, Set<String>)] = [
            (capabilities.canManageConversationApps, ["addApp", "removeApp"]),
            (capabilities.canManageConversationWebhooks, ["createWebhook", "editWebhook", "deleteWebhook"]),
            (capabilities.canManageConversationEmail, ["generateEmail", "setEmailDelivery", "deleteEmail"]),
            (capabilities.canBlockConversations, ["blockPerson", "unblockPerson"])
        ]
        for (supported, actions) in flags where !supported {
            details.allowedActions.subtract(actions)
        }
        if let viewer = managedParticipants[details.conversation.id]?.first(where: { $0.id == world.me }),
           viewer.role != .owner || viewer.state != .joined {
            details.allowedActions.subtract(["deleteEmail", "deleteSpace"])
        }
        return details
    }
}
