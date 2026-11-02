import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct ManagementMappingTests {
    @Test func invitationCanBeRemovedButDoesNotOfferJoinedRoleChanges() {
        var group = GroupId(); group.spaceID.spaceID = "space"
        var row = Membership()
        row.id = ConversationManagementRequests.membershipID(group: group, user: "peer")
        row.membershipState = .memberInvited; row.membershipRole = .roleMember
        var caps = GroupScopedCapabilities(); caps.capabilities = [2, 4, 60]
        let invited = ManagementMapping.participant(
            row, group: group, me: .init("me"), people: [:], caps: caps
        )
        #expect(invited?.allowedActions == ["removePerson"])
        #expect(invited?.allowedRoles.isEmpty == true)
        caps.capabilities = []
        #expect(ManagementMapping.participant(
            row, group: group, me: .init("me"), people: [:], caps: caps
        )?.allowedActions.isEmpty == true)
    }

    @Test func deletionRequiresItsOwnPermissionAndHonorsExplicitRefusal() throws {
        var caps = GroupScopedCapabilities()
        #expect(!ManagementMapping.canDeleteSpace(caps))
        caps.capabilities = [2]
        #expect(ManagementMapping.canDeleteSpace(caps))
        caps.permissions = try ManagementPermissions(serializedBytes: Data([0x18, 0x00]))
        #expect(!ManagementMapping.canDeleteSpace(caps))
        caps.capabilities = []
        caps.permissions = try ManagementPermissions(serializedBytes: Data([0x18, 0x01]))
        #expect(ManagementMapping.canDeleteSpace(caps))
    }

    @Test func anUnknownRoleCannotBorrowTheDefaultRolesPrivileges() throws {
        var group = GroupId(); group.spaceID.spaceID = "space"
        var row = try Membership(serializedBytes: Data([0x28, 0xA0, 0x06]))
        row.id = ConversationManagementRequests.membershipID(group: group, user: "peer")
        row.membershipState = .memberJoined
        var caps = GroupScopedCapabilities(); caps.capabilities = [2, 4, 60]
        let value = ManagementMapping.participant(
            row, group: group, me: .init("me"), people: [:], caps: caps, viewerIsOwner: true
        )
        #expect(value?.allowedRoles.isEmpty == true)
        #expect(value?.allowedActions.isEmpty == true)
    }

    @Test func absentPermissionsAndUnknownRolesNeverGrantAnEdit() throws {
        #expect(ManagementMapping.actions(GroupScopedCapabilities(), joined: true).isEmpty)
        #expect(try ManagementMapping.role(in: Membership(serializedBytes: Data([0x28, 0xA0, 0x06])))
            .type == "provider:800")
        #expect(ManagementMapping.role(ConversationRole("future")) == nil)
        let future = try Membership(serializedBytes: Data([0x18, 0xA0, 0x06]))
        #expect(ManagementMapping.state(future.membershipState, unknown: future.unknownFields.data)
            .type == "provider:800")
    }

    @Test func explicitRefusalOverridesLegacyGrant() throws {
        var caps = GroupScopedCapabilities()
        caps.capabilities = [14]
        caps.permissions = try ManagementPermissions(serializedBytes: Data([0x70, 0x00]))
        #expect(!ManagementMapping.grants(caps, 14))
        #expect(!ManagementMapping.actions(caps, joined: true).contains("addPeople"))
    }

    @Test func addPeopleUsesMemberManagementRatherThanHeaderCapability() throws {
        var caps = GroupScopedCapabilities()
        caps.permissions = try ManagementPermissions(serializedBytes: Data([0x70, 1, 0xB0, 3, 0]))
        #expect(ManagementMapping.actions(caps, joined: true).contains("addPeople"))
        caps.permissions = try ManagementPermissions(serializedBytes: Data([0x70, 0, 0xB0, 3, 1]))
        #expect(!ManagementMapping.actions(caps, joined: true).contains("addPeople"))
    }

    @Test func targetPermissionsDoNotApplyToSelfOrForeignMemberships() {
        var group = GroupId(); group.dmID.dmID = "group"
        var row = Membership()
        row.id = ConversationManagementRequests.membershipID(group: group, user: "me")
        row.membershipState = .memberJoined; row.membershipRole = .roleMember
        var caps = GroupScopedCapabilities(); caps.capabilities = [2, 4, 60]
        let participant = ManagementMapping.participant(
            row,
            group: group,
            me: .init("me"),
            people: [:],
            caps: caps
        )
        #expect(participant?.allowedActions.isEmpty == true)
        row.id.groupID.dmID.dmID = "foreign"
        #expect(ManagementMapping
            .participant(row, group: group, me: .init("me"), people: [:], caps: caps) == nil)
    }

    /// Measured on a live space: two owners, permission 4 granted, and Chat on
    /// the web offers either owner "Remove from space".
    @Test func anOwnerMayRemoveAnotherOwnerButNobodyElseMay() {
        var group = GroupId(); group.dmID.dmID = "group"
        var row = Membership()
        row.id = ConversationManagementRequests.membershipID(group: group, user: "peer")
        row.membershipState = .memberJoined; row.membershipRole = .roleOwner
        var caps = GroupScopedCapabilities(); caps.capabilities = [4]
        let byOwner = ManagementMapping.participant(
            row, group: group, me: .init("me"), people: [:], caps: caps, viewerIsOwner: true
        )
        #expect(byOwner?.allowedActions.contains("removePerson") == true)
        let byManager = ManagementMapping.participant(
            row, group: group, me: .init("me"), people: [:], caps: caps, viewerIsOwner: false
        )
        #expect(byManager?.allowedActions.contains("removePerson") == false)
        caps.capabilities = []
        let withoutGrant = ManagementMapping.participant(
            row, group: group, me: .init("me"), people: [:], caps: caps, viewerIsOwner: true
        )
        #expect(withoutGrant?.allowedActions.contains("removePerson") == false)
    }

    @Test func cursorsCannotCrossQueriesOrConversations() throws {
        let cursor = ManagementCursor.encode("opaque", key: "account:people:first")
        #expect(try ManagementCursor.decode(cursor, key: "account:people:first") == "opaque")
        #expect(throws: (any Error).self) {
            try ManagementCursor.decode(cursor, key: "account:people:second")
        }
        #expect(throws: (any Error).self) {
            try ManagementCursor.decode("malformed", key: "account:people:first")
        }
    }
}

/// Fictional explicit permission booleans, encoded independently of the proto's
/// unknown-field storage. Legacy capability lists are deliberately separate.
func explicitManagementPermissions(_ fields: [Int32]) throws -> ManagementPermissions {
    var bytes = Data()
    for field in fields {
        var tag = UInt64(field) << 3
        while tag > 127 {
            bytes.append(UInt8(tag & 127) | 128)
            tag >>= 7
        }
        bytes.append(UInt8(tag))
        bytes.append(1)
    }
    return try ManagementPermissions(serializedBytes: bytes)
}
