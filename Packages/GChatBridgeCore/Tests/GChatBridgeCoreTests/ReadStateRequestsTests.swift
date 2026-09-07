import Foundation
import Testing
@testable import GChatBridgeCore

/// The `mark_group_readstate` request shape.
///
/// Shape from `reference/googlechat-master/maugclib/client.py:730-736` -
/// `request_header` + `id` + `last_read_time` and nothing else. **No ladder**,
/// for the reason `SendRequests`' own doc comment gives: this is a write, and
/// four candidate shapes would mis-set read state four times on a real
/// account.
struct ReadStateRequestsTests {
    private func spaceGroup(_ id: String) -> GroupId {
        var space = SpaceId()
        space.spaceID = id
        var group = GroupId()
        group.spaceID = space
        return group
    }

    @Test func markGroupReadCarriesTheGroupAndTheWatermark() {
        let request = ReadStateRequests.markGroupRead(
            group: spaceGroup("s-1"),
            lastReadTime: 1_700_000_000_000_000
        )

        #expect(request.hasRequestHeader)
        #expect(request.id.spaceID.spaceID == "s-1")
        #expect(request.lastReadTime == 1_700_000_000_000_000)
    }

    /// A DM id and a space id are different namespaces, and the request must
    /// carry whichever one it was handed rather than flattening them.
    @Test func markGroupReadCarriesDMGroupUnchanged() {
        var dm = DmId()
        dm.dmID = "dm-1"
        var group = GroupId()
        group.dmID = dm

        let request = ReadStateRequests.markGroupRead(group: group, lastReadTime: 1)

        #expect(request.id.dmID.dmID == "dm-1")
        guard case .dmID = request.id.id else {
            Issue.record("expected the dm namespace, got \(String(describing: request.id.id))")
            return
        }
    }

    @Test func theMethodNameIsTheReferencesOwn() {
        let method: APIMethod<MarkGroupReadstateRequest, MarkGroupReadstateResponse> = .markGroupReadstate
        #expect(method.name == "mark_group_readstate")
    }
}
