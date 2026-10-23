import ChatKit
import Foundation
import GChatBridgeCore

enum SpaceSettingsMapping {
    struct Policy {
        var id: String
        var number: Int32
        var grant: Int
    }

    static let policies: [Policy] = [
        Policy(id: "viewMembers", number: 23, grant: 67),
        Policy(id: "manageMembers", number: 9, grant: 25),
        Policy(id: "modifyDetails", number: 3, grant: 26),
        Policy(id: "changeHistory", number: 1, grant: 23),
        Policy(id: "mentionAll", number: 2, grant: 24),
        Policy(id: "manageApps", number: 20, grant: 41),
        Policy(id: "manageWebhooks", number: 21, grant: 42)
    ]

    static func organizationAudience(_ values: [SpacePermissionAudience]) -> SpacePermissionAudience? {
        guard let first = values.first, first.type == 1, !first.id.id.isEmpty else { return nil }
        return first
    }

    static func access(_ group: Group, defaultAudience: SpacePermissionAudience?) -> ConversationAccess {
        let find = group.spacePermissions.rules.filter { $0.permission == 24 }
        let join = group.spacePermissions.rules.filter { $0.permission == 25 }
        guard find.count == 1, join.count == 1 else { return .unknown }
        let findAudiences = find[0].audiences.audiences
        let joinAudiences = join[0].audiences.audiences
        if findAudiences.isEmpty, joinAudiences.isEmpty {
            return .restricted
        }
        guard let defaultAudience else { return .unknown }
        let finds = findAudiences.count == 1 && findAudiences[0].id == defaultAudience.id
        let joins = joinAudiences.count == 1 && joinAudiences[0].id == defaultAudience.id
        if finds, joins {
            return .open
        }
        if finds, joinAudiences.isEmpty {
            return .discoverable
        }
        return ConversationAccess("custom")
    }

    static func audience(
        _ rule: SpacePermissionRule, organization: SpacePermissionAudience? = nil
    ) -> PermissionAudience {
        guard rule.hasRoles, rule.roles.owners else { return .unknown }
        let roles = rule.roles
        if !rule.audiences.audiences.isEmpty {
            return roles.members && roles.managers && rule.audiences.audiences.count == 1
                && rule.audiences.audiences[0].type == 1
                && organization != nil && rule.audiences.audiences[0].id == organization?.id
                ? .organization : .unknown
        }
        if roles.organization {
            return roles.members && roles.managers ? .organization : .unknown
        }
        if roles.members {
            return roles.managers ? .members : .unknown
        }
        return roles.managers ? .managers : .owners
    }

    static func settings(
        _ group: Group,
        caps: GroupScopedCapabilities,
        defaultTargetAudiences: [SpacePermissionAudience] = []
    ) -> ConversationSettings {
        let rules = group.spacePermissions.rules
        let request = rules.filter { $0.permission == 22 }
        let organization = organizationAudience(defaultTargetAudiences)
        let access = access(group, defaultAudience: organization)
        return ConversationSettings(
            permissions: policies.compactMap { policy in
                let matches = rules.filter { $0.permission == policy.number }
                guard matches.count == 1, let rule = matches.first else { return nil }
                let value = audience(rule, organization: organization)
                return ConversationPermission(
                    id: policy.id, audience: value,
                    isEditable: value != .unknown && ManagementMapping.grants(caps, policy.grant),
                    allowedAudiences: value == .unknown ? [] : [.owners, .managers, .members]
                        + (policy.id == "viewMembers" && organization != nil ? [.organization] : [])
                )
            },
            requestToJoin: request.count == 1 ? request.first.map {
                !$0.audiences.audiences.isEmpty
            } : nil,
            externalMembersAllowed: group.hasGuestAccess && [1, 2].contains(group.guestAccess.state)
                ? group.guestAccess.state == 2 : nil,
            emoji: group.avatarInfo.emoji.hasUnicode ? group.avatarInfo.emoji.unicode : nil,
            canChangeAccess: organization != nil && access != .unknown && access !=
                ConversationAccess("custom")
                && ManagementMapping.grants(caps, 68) && ManagementMapping.grants(caps, 73),
            canChangeRequestToJoin: request.count == 1 && standardRequestAudience(
                request[0],
                organization: organization
            )
                && organization != nil && [.restricted, .discoverable]
                .contains(access) && ManagementMapping.grants(
                    caps,
                    65
                )
        )
    }

    private static func standardRequestAudience(
        _ rule: SpacePermissionRule, organization: SpacePermissionAudience?
    ) -> Bool {
        let audiences = rule.audiences.audiences
        return audiences.isEmpty || audiences.count == 1 && organization != nil
            && audiences[0].id == organization?.id
    }

    static func validateMembershipVisibility(
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

    static func changing(
        _ set: SpacePermissionSet, to changes: [String: PermissionAudience],
        organizationAudience: SpacePermissionAudience? = nil
    ) throws -> SpacePermissionSet {
        var result = set
        for (id, value) in changes {
            guard let policy = policies.first(where: { $0.id == id }),
                  let index = result.rules.firstIndex(where: { $0.permission == policy.number }),
                  result.rules.filter({ $0.permission == policy.number }).count == 1,
                  [.owners, .managers, .members, .organization].contains(value),
                  value != .organization || id == "viewMembers" && organizationAudience != nil else {
                throw ChatError.unsupported(capability: "conversationPermission")
            }
            var roles = result.rules[index].roles
            roles.owners = true
            roles.managers = value != .owners
            roles.members = value == .members || value == .organization
            roles.organization = false
            result.rules[index].roles = roles
            result.rules[index].clearAudiences()
            if value == .organization {
                if let organizationAudience {
                    result.rules[index].audiences.audiences = [organizationAudience]
                }
            }
        }
        return result
    }

    static func changingAccess(
        _ set: SpacePermissionSet,
        to access: ConversationAccess,
        organization: SpacePermissionAudience
    ) throws -> SpacePermissionSet {
        guard [.restricted, .discoverable, .open].contains(access) else {
            throw ChatError.unsupported(capability: "conversationAccess")
        }
        var result = set
        for number: Int32 in [24, 25] {
            guard let index = result.rules.firstIndex(where: { $0.permission == number }),
                  result.rules.filter({ $0.permission == number }).count == 1 else {
                throw ChatError.unsupported(capability: "conversationAccess")
            }
            let find = number == 24
            result.rules[index].roles.owners = find
            result.rules[index].roles.managers = find
            result.rules[index].roles.members = find
            result.rules[index].roles.organization = true
            result.rules[index].clearAudiences()
            if find && access != .restricted || !find && access == .open {
                result.rules[index].audiences.audiences = [organization]
            }
        }
        return result
    }
}
