import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct SpacePolicyMappingTests {
    @Test func audienceConfirmationDistinguishesIDlessPredicatesByType() throws {
        var rule = SpacePermissionRule(); rule.permission = 22
        rule.audiences.audiences = [SpacePermissionAudience()]
        rule.audiences.audiences[0].type = 1
        var expected = SpacePermissionSet(); expected.rules = [rule]
        var actual = expected
        actual.rules[0].audiences.audiences[0].type = 2
        #expect(!SpaceSettingsMapping.confirms(expected, in: actual))
        actual.rules[0].audiences.audiences[0].type = 1
        #expect(SpaceSettingsMapping.confirms(expected, in: actual))
        var opaque = try SpacePermissionAudience(serializedBytes: Data([0x28, 1]))
        opaque.type = 1
        actual.rules[0].audiences.audiences = [opaque]
        #expect(!SpaceSettingsMapping.confirms(expected, in: actual))
        var group = Group(); group.spacePermissions = actual
        var find = SpacePermissionRule(); find.permission = 24
        var join = SpacePermissionRule(); join.permission = 25
        group.spacePermissions.rules += [find, join]
        var caps = GroupScopedCapabilities(); caps.permissions = try explicitManagementPermissions([65])
        #expect(!SpaceSettingsMapping.settings(group, caps: caps).canChangeRequestToJoin)
    }

    @Test func accessRequiresItsOwnGrantWithoutAnUnrelatedGrant73() throws {
        var group = Group()
        var find = SpacePermissionRule(); find.permission = 24
        var join = SpacePermissionRule(); join.permission = 25
        group.spacePermissions.rules = [find, join]
        var audience = SpacePermissionAudience(); audience.id.id = "default"; audience.type = 1
        var caps = GroupScopedCapabilities(); caps.capabilities = [68]
        let legacyOnly = SpaceSettingsMapping.settings(group, caps: caps, defaultTargetAudiences: [audience])
        #expect(!legacyOnly.canChangeAccess)
        caps.permissions = try explicitManagementPermissions([68])
        #expect(SpaceSettingsMapping.settings(group, caps: caps, defaultTargetAudiences: [audience])
            .canChangeAccess)
        caps.permissions = try ManagementPermissions(serializedBytes: Data([0xA0, 4, 0]))
        #expect(!SpaceSettingsMapping.settings(group, caps: caps, defaultTargetAudiences: [audience])
            .canChangeAccess)
        caps.permissions = try explicitManagementPermissions([68])
        group.guestAccess.state = 2
        #expect(!SpaceSettingsMapping.settings(group, caps: caps, defaultTargetAudiences: [audience])
            .canChangeAccess)
    }

    @Test func anOrganizationAudienceMustHaveAnActualUnambiguousID() {
        var rule = SpacePermissionRule(); rule.roles.owners = true; rule.roles.managers = true
        rule.roles.members = true; rule.roles.organization = true
        #expect(SpaceSettingsMapping.audience(rule).type == "custom")
        var other = SpacePermissionAudience(); other.type = 2; other.id.id = "other"
        var organization = SpacePermissionAudience()
        organization.type = 1; organization.id.id = "organization"
        #expect(SpaceSettingsMapping.organizationAudience([other, organization]) == organization)
        var second = organization; second.id.id = "second"
        #expect(SpaceSettingsMapping.organizationAudience([organization, second]) == nil)
    }

    @Test func replyPermissionIsReturnedReadOnlyWithoutItsOwnEditGrant() throws {
        var rule = SpacePermissionRule(); rule.permission = 5
        rule.roles.owners = true; rule.roles.managers = true; rule.roles.members = true
        var group = Group(); group.spacePermissions.rules = [rule]
        var caps = GroupScopedCapabilities()
        let readOnly = SpaceSettingsMapping.settings(group, caps: caps).permissions.first
        #expect(readOnly?.id == "replyMessages" && readOnly?.isEditable == false)
        caps.capabilities = [43]
        #expect(SpaceSettingsMapping.settings(group, caps: caps).permissions.first?.isEditable == false)
        caps.permissions = try explicitManagementPermissions([43])
        #expect(SpaceSettingsMapping.settings(group, caps: caps).permissions.first?.isEditable == true)
    }

    @Test func nondefaultOrganizationAudienceRemainsReadOnly() throws {
        var audience = SpacePermissionAudience(); audience.id.id = "default"; audience.type = 1
        var custom = audience; custom.id.id = "custom"
        var rule = SpacePermissionRule(); rule.permission = 23
        rule.roles.owners = true; rule.roles.managers = true; rule.roles.members = true
        rule.audiences.audiences = [custom]
        var request = SpacePermissionRule(); request.permission = 22; request.audiences.audiences = [custom]
        var find = SpacePermissionRule(); find.permission = 24
        var join = SpacePermissionRule(); join.permission = 25
        var group = Group(); group.spacePermissions.rules = [rule, request, find, join]
        var caps = GroupScopedCapabilities(); caps.capabilities = [65, 67, 68, 73]
        caps.permissions = try explicitManagementPermissions([65, 67, 68, 73])
        let value = SpaceSettingsMapping.settings(group, caps: caps, defaultTargetAudiences: [audience])
        #expect(value.permissions.first?.audience.type == "custom")
        #expect(value.permissions.first?.isEditable == false)
        #expect(!value.canChangeRequestToJoin)
    }

    @Test func membershipManagementCannotExceedVisibilityButUnrelatedEditsPreserveExistingPolicies() throws {
        let current = [
            ConversationPermission(id: "viewMembers", audience: .managers),
            ConversationPermission(id: "manageMembers", audience: .members)
        ]
        #expect(throws: ChatError.self) {
            try SpaceSettingsMapping.validateMembershipVisibility(["viewMembers": .owners], current: current)
        }
        try SpaceSettingsMapping.validateMembershipVisibility(["manageMembers": .managers], current: current)
        try SpaceSettingsMapping.validateMembershipVisibility(["mentionAll": .owners], current: current)
    }
}
