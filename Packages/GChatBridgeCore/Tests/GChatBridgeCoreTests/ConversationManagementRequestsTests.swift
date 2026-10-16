import Foundation
import Testing
@testable import GChatBridgeCore

struct ConversationManagementRequestsTests {
    @Test func directoryCountsUseTheSummarysNestedFieldTen() throws {
        // Field10 -> repeated counts1; each count has total1, member kind2, membership3.
        let summary = try SearchSpaceDirectoryResponse.Summary(serializedBytes: Data([
            0x52, 16, 0x0A, 6, 8, 7, 16, 1, 24, 2, 0x0A, 6, 8, 1, 16, 2, 24, 2
        ]))
        #expect(summary.memberCounts.counts.map(\.count) == [7, 1])
        #expect(summary.memberCounts.counts.map(\.memberType) == [1, 2])
        #expect(summary.memberCounts.counts.allSatisfy { $0.membershipState == .memberJoined })
    }

    @Test(arguments: [0, 1, 2], [0, 1, 2])
    func directoryFiltersMatchTheWebControls(_ membership: Int, _ organization: Int) throws {
        let memberships: [ConversationManagementRequests.DirectoryMembership] = [.all, .joined, .notJoined]
        let organizations: [ConversationManagementRequests.DirectoryOrganization] = [
            .all, .internalOnly, .externalOnly
        ]
        let request = ConversationManagementRequests.discover(
            "query", token: "next", membership: memberships[membership],
            organization: organizations[organization]
        )
        let terms: [[UInt8]] = [
            [],
            [0x0A, 4, 8, 1, 16, 0],
            [0x0A, 4, 8, 3, 16, 2, 0x0A, 4, 8, 2, 16, 0]
        ]
        let origin: [UInt8] = [0, 2, 1]
        let expected = Data([0x0A, UInt8(terms[membership].count)] + terms[membership] +
            [0x10, origin[organization]])
        let bytes = try request.serializedData()
        #expect(ProtoFieldScan.payloads(ofField: 8, in: bytes) == [expected])
        #expect(request.query == "query" && request.pageToken == "next")
    }

    @Test func spamInvitationsUseTheNativeInviteCategoryField() throws {
        let spam = try ConversationManagementRequests.invitations(spam: true).serializedData()
        let regular = try ConversationManagementRequests.invitations().serializedData()
        #expect(ProtoFieldScan.varintValues(ofField: 1, in: spam) == [2])
        #expect(ProtoFieldScan.varintValues(ofField: 1, in: regular) == [1])
    }

    @Test func discoveryMatchesTheVerifiedUnjoinedDirectoryRequest() throws {
        var request = ConversationManagementRequests.discover("query", token: "next")
        request.clearRequestHeader()
        // Independent wire fixture: native paging plus the verified web directory settings.
        let expected = Data([
            0x08, 50, 0x12, 4, 110, 101, 120, 116,
            0x20, 1, 0x2A, 5, 113, 117, 101, 114, 121, 0x32, 0,
            0x42, 16, 0x0A, 12, 0x0A, 4, 8, 3, 16, 2, 0x0A, 4, 8, 2, 16, 0, 0x10, 0,
            0x48, 0
        ])
        #expect(try request.serializedData() == expected)
    }

    @Test func directoryContinuationComesFromResponseFieldOneNotFieldThree() throws {
        // Independent wire fixture: field1="next", field3="other". Do not encode with the schema under test.
        let bytes = Data([0x0A, 4, 110, 101, 120, 116, 0x1A, 5, 111, 116, 104, 101, 114])
        let response = try SearchSpaceDirectoryResponse(serializedBytes: bytes)
        #expect(response.nextPageToken == "next")
    }

    @Test func spaceDeletionPreservesTheLinkedGroupAndUsesTheModernEndpoint() throws {
        var group = GroupId(); group.spaceID.spaceID = "disposable"
        let request = ConversationManagementRequests.deleteSpace(group)
        #expect(request.groupID == group)
        #expect(request.hasRequestHeader)
        #expect(request.hasPreserveLinkedGroup && request.preserveLinkedGroup)
        let bytes = try request.serializedData()
        #expect(ProtoFieldScan.varintValues(ofField: 2, in: bytes) == [1])
        #expect(APIMethod<DeleteGroupV2Request, DeleteGroupV2Response>.deleteGroupV2
            .name == "delete_group_v2")
    }

    @Test func creationDoesNotSendAMessageOrChangeHistorySettings() throws {
        let request = ConversationManagementRequests.create(
            name: "Planning",
            description: "Weekly plans",
            people: ["person"],
            space: true,
            localID: "local"
        )
        #expect(request.space.attributeCheckerGroupType == .flatRoom)
        #expect(request.space.spaceDetails.description_p == "Weekly plans")
        #expect(request.space.inviteeMemberInfos.first?.inviteeInfo.userID.id == "person")
        #expect(!request.space.hasFlatGroup)
        #expect(!request.space.hasThreadedGroup)
        #expect(request.hasRequestHeader)
        let fields = try CreateGroupRequest(serializedBytes: request.serializedData())
        #expect(fields == request)
    }

    @Test func renameUsesGroupReferenceAndExplicitMasks() {
        var group = GroupId(); group.dmID.dmID = "group"
        let request = ConversationManagementRequests.identity(group, name: "New name", description: "")
        #expect(request.groupID == group)
        #expect(!request.hasSpaceID)
        #expect(request.updateMasks == [.name, .spaceDetails])
        #expect(request.spaceDetails.hasDescription_p)
        #expect(request.spaceDetails.description_p.isEmpty)
        #expect(!request.hasVisibility)
    }

    @Test func roleChangeUsesUserIDRatherThanMemberID() {
        var group = GroupId(); group.spaceID.spaceID = "space"
        let request = ConversationManagementRequests.role(.roleManager, user: "person", group: group)
        #expect(request.changes.count == 1)
        #expect(request.changes[0].userID.id == "person")
        #expect(request.changes[0].role.rawValue == 6)
        #expect(request.changes[0].groupID == group)
    }

    @Test func requestingMembershipDoesNotAlsoJoin() {
        var group = GroupId(); group.spaceID.spaceID = "space"
        let request = ConversationManagementRequests.add(["me"], group: group, requestJoin: true)
        #expect(request.requestToJoin)
        #expect(!request.hasMembershipState)
        #expect(request.memberIds[0].userID.id == "me")
        let join = ConversationManagementRequests.add(["me"], group: group, join: true)
        #expect(join.membershipState == .memberJoined)
        #expect(!join.hasRequestToJoin)
    }
}
