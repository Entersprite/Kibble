import ChatKit
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct SpacePolicyMappingTests {
    @Test func nondefaultOrganizationAudienceRemainsReadOnly() {
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
        let value = SpaceSettingsMapping.settings(group, caps: caps, defaultTargetAudiences: [audience])
        #expect(value.permissions.first?.audience == .unknown)
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
