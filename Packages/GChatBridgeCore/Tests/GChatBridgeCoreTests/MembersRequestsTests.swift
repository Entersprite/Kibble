import Foundation
import Testing
@testable import GChatBridgeCore

/// `list_members` as Chat on the web sends it (`findings.md` §56.1), and its
/// answer decoded from a fixture whose **syntax** is the captured response's,
/// with every value invented (CLAUDE.md: "a fixture is not a capture").
struct MembersRequestsTests {
    private func space(_ id: String) -> GroupId {
        var group = GroupId()
        var space = SpaceId()
        space.spaceID = id
        group.spaceID = space
        return group
    }

    @Test func theRequestCarriesTheWebClientsFields() {
        let request = MembersRequests.listMembers(group: space("s-1"), pageToken: nil)
        #expect(request.groupID.spaceID.spaceID == "s-1")
        #expect(request.fetchOptions == [4, 5])
        #expect(request.filter == 1)
        #expect(request.hasRequestHeader)
        #expect(!request.hasPageToken)
        #expect(!request.hasPageSize)
    }

    @Test func aPageTokenIsSentWhenGiven() {
        let request = MembersRequests.listMembers(group: space("s-1"), pageToken: "next")
        #expect(request.pageToken == "next")
    }

    /// Fields 2 and 7 on the wire, by number: a byte walk, so a proto edit
    /// that renamed or renumbered them fails here.
    @Test func fieldsTwoAndSevenAreOnTheWire() throws {
        let bytes: Data = try MembersRequests.listMembers(group: space("s-1"), pageToken: nil)
            .serializedBytes()
        #expect(ProtoFieldScan.varintValues(ofField: 2, in: bytes) == [4, 5])
        #expect(ProtoFieldScan.varintValues(ofField: 7, in: bytes) == [1])
    }

    /// The owner's capture (§56.1), every string and timestamp replaced; the
    /// nesting, positions and small integers are the real response's. Element
    /// 0 is the response's type tag.
    static let capturedShape = #"""
    ["tag",[[[[["u-1"]],null,[["s-1"]]],"1700000000000001",2,null,4],\#
    [[[["u-2"]],null,[["s-1"]]],"1700000000000002",2,null,3],\#
    [[[["u-3",1]],null,[["s-1"]]],"1700000000000003",2,null,3]],\#
    null,"",["1700000000000004"],null,null,[["xxxxxxxxxxxxxxx",["u-4"],1,1]],null,null,true,null,[1]]
    """#

    @Test func theCapturedResponseDecodesToJoinedMemberships() throws {
        let decoded = try PBLiteDecoder.decode(
            ListMembersResponse.self, fromJSON: Data(Self.capturedShape.utf8), ignoreFirstItem: true
        ).message
        #expect(decoded.memberships.count == 3)
        let first = try #require(decoded.memberships.first)
        #expect(first.id.memberID.userID.id == "u-1")
        #expect(first.id.groupID.spaceID.spaceID == "s-1")
        #expect(first.membershipState == .memberJoined)
        #expect(first.membershipRole == .roleOwner)
        #expect(first.createTime == 1_700_000_000_000_001)
        #expect(decoded.nextPageToken.isEmpty)
        #expect(decoded.memberships.map(\.id.memberID.userID.id) == ["u-1", "u-2", "u-3"])
    }
}
