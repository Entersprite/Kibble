import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct ManagementMappingTests {
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
        caps.capabilities = [54]
        caps.permissions = try ManagementPermissions(serializedBytes: Data([0xB0, 0x03, 0x00]))
        #expect(!ManagementMapping.grants(caps, 54))
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
