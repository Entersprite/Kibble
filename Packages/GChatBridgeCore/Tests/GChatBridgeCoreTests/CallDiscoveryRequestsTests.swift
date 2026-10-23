import Foundation
import GChatBridgeCore
import Testing

struct CallDiscoveryRequestsTests {
    @Test func participantsUsesWebGroupReferencesAndTheExplicitFetchOption() throws {
        for space in [false, true] {
            var group = GroupId()
            if space {
                group.spaceID.spaceID = "example"
            } else {
                group.dmID.dmID = "example"
            }
            let call = try CallDiscoveryRequests.participants(in: group)
            #expect(call.rpc == "v54cwf")
            #expect(call.payload == (space ? "[[\"space/example\",\"example\",2],[1]]"
                    : "[[\"dm/example\",\"example\",5],[1]]"))
        }
        #expect(throws: CallDiscoveryRequests.Failure.self) {
            try CallDiscoveryRequests.participants(in: GroupId())
        }
    }

    @Test func rosterPreservesAnonymousPeopleAndAnIncompleteCount() throws {
        let value = try CallDiscoveryRequests.participants(
            from: "[[[[\"first\",1],[\"second\",1]],5,null,[[\"Guest\"],[]]]]"
        )
        #expect(value.memberIDs == ["first", "second"])
        #expect(value.anonymousNames == ["Guest", nil])
        #expect(value.totalCount == 5)
        let empty = try CallDiscoveryRequests.participants(from: "[[[],0]]")
        #expect(empty.totalCount == 0)
        #expect(empty.memberIDs.isEmpty)
    }

    @Test(arguments: [
        "[]", "[null]", "[[[]]]", "[[[],true]]", "[[[],1.5]]", "[[[],10001]]",
        "[[[[\"same\"],[\"same\"]],2]]", "[[[[\"first\"]],0]]", "[[[[null]],1]]",
        "[[[],1,null,[[42]]]]"
    ])
    func malformedRosterIsNeverAnAuthoritativeEmptyList(_ payload: String) {
        #expect(throws: (any Error).self) { try CallDiscoveryRequests.participants(from: payload) }
    }
}
