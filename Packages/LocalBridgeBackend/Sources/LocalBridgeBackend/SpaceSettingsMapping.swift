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
        Policy(id: "replyMessages", number: 5, grant: 43),
        Policy(id: "mentionAll", number: 2, grant: 24),
        Policy(id: "manageApps", number: 20, grant: 41),
        Policy(id: "manageWebhooks", number: 21, grant: 42)
    ]

    static func organizationAudience(_ values: [SpacePermissionAudience]) -> SpacePermissionAudience? {
        let standard = values.filter { $0.type == 1 && !$0.id.id.isEmpty }
        return standard.count == 1 ? standard.first : nil
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
        guard rule.hasRoles else { return .unknown }
        let custom = PermissionAudience("custom")
        guard rule.roles.owners else { return custom }
        let roles = rule.roles
        if !rule.audiences.audiences.isEmpty {
            return roles.members && roles.managers && rule.audiences.audiences.count == 1
                && rule.audiences.audiences[0].type == 1
                && organization != nil && rule.audiences.audiences[0].id == organization?.id
                ? .organization : custom
        }
        // A role flag for non-members is not an organization audience ID.
        if roles.organization {
            return custom
        }
        if roles.members {
            return roles.managers ? .members : custom
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
                    isEditable: [.owners, .managers, .members, .organization].contains(value)
                        && ManagementMapping.explicitGrant(caps, policy.grant),
                    allowedAudiences: value == .unknown || value.type == "custom" ? [] : [
                        .owners,
                        .managers,
                        .members
                    ]
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
                && !(group.hasGuestAccess && group.guestAccess.state == 2)
                && ManagementMapping.explicitGrant(caps, 68),
            canChangeRequestToJoin: request.count == 1 && standardRequestAudience(
                request[0],
                organization: organization
            )
                && [.restricted, .discoverable]
                .contains(access) && ManagementMapping.explicitGrant(
                    caps,
                    65
                )
        )
    }

    /// Ordinary policies use a diff. An access preset supplies its complete join/find pair.
    static func patch(
        _ updated: SpacePermissionSet,
        over original: SpacePermissionSet,
        includeAccess: Bool = false
    ) -> SpacePermissionSet {
        var result = SpacePermissionSet()
        result.rules = updated.rules.filter { rule in
            !(includeAccess && [24, 25].contains(rule.permission))
                && original.rules.first { $0.permission == rule.permission } != rule
        }
        if includeAccess {
            result.rules += [Int32(25), 24].compactMap { number in
                updated.rules.first { $0.permission == number }
            }
        }
        return result
    }

    /// Replies may omit unchanged policies or normalize absent false booleans.
    static func confirms(_ expected: SpacePermissionSet, in received: SpacePermissionSet) -> Bool {
        expected.rules.allSatisfy { rule in
            let matches = received.rules.filter { $0.permission == rule.permission }
            guard matches.count == 1, let actual = matches.first else { return false }
            return actual.roles.owners == rule.roles.owners
                && actual.roles.managers == rule.roles.managers && actual.roles.members == rule.roles.members
                && actual.roles.organization == rule.roles.organization
                && actual.roles.role5 == rule.roles.role5
                && audienceIdentities(actual.audiences) == audienceIdentities(rule.audiences)
        }
    }

    private enum AudienceIdentity: Hashable {
        case selected(SpaceAudienceId)
        case predicate(Int32, Data, Data)
    }

    private static func audienceIdentities(_ audiences: SpacePermissionAudiences) -> Set<AudienceIdentity> {
        Set(audiences.audiences.map {
            $0.id.id.isEmpty
                ? .predicate($0.type, $0.unknownFields.data, $0.id.unknownFields.data)
                : .selected($0.id)
        })
    }

    private static func standardRequestAudience(
        _ rule: SpacePermissionRule, organization: SpacePermissionAudience?
    ) -> Bool {
        let audiences = rule.audiences.audiences
        guard audiences.count == 1 else { return audiences.isEmpty }
        let audience = audiences[0]
        if audience.id.id.isEmpty {
            return audience.type == 1 && audience.unknownFields.data.isEmpty
                && audience.id.unknownFields.data.isEmpty
        }
        return organization != nil && audience.id == organization?.id
    }

    static func changingJoinRequests(
        _ set: SpacePermissionSet,
        to enabled: Bool
    ) throws -> SpacePermissionSet {
        var result = set
        guard let index = result.rules.firstIndex(where: { $0.permission == 22 }),
              result.rules.filter({ $0.permission == 22 }).count == 1 else {
            throw ChatError.unsupported(capability: "requestToJoin")
        }
        result.rules[index].roles.owners = false
        result.rules[index].roles.managers = false
        result.rules[index].roles.members = false
        result.rules[index].roles.organization = false
        result.rules[index].roles.role5 = false
        // Join requests use a predicate, not a selected target audience. Match the
        // native converter's explicit empty name/ID and unspecified state.
        var predicate = SpacePermissionAudience()
        predicate.name = ""; predicate.id.id = ""; predicate.state = 0; predicate.type = 1
        result.rules[index].audiences.audiences = enabled ? [predicate] : []
        return result
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
