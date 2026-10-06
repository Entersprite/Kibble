import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The probe's member-list section prints counts only: never an id.
struct APIProbeReportMemberListTests {
    private func page(
        states: [MembershipState],
        roles: [MembershipRole],
        next: String = ""
    ) -> ListMembersResponse {
        var response = ListMembersResponse()
        response.memberships = zip(states, roles).enumerated().map { index, pair in
            var user = UserId()
            user.id = "secret-id-\(index)"
            var member = MemberId()
            member.userID = user
            var id = MembershipId()
            id.memberID = member
            var membership = Membership()
            membership.id = id
            membership.membershipState = pair.0
            membership.membershipRole = pair.1
            return membership
        }
        response.nextPageToken = next
        return response
    }

    @Test func countsStatesRolesAndPagesAndNamesNobody() {
        let lines = APIProbeReport.memberListLines([
            page(
                states: [.memberJoined, .memberJoined],
                roles: [.roleOwner, .roleMember],
                next: "lowercase-token"
            ),
            page(states: [.memberInvited], roles: [.roleInvitee])
        ])
        let text = lines.joined(separator: "\n")
        #expect(text.contains("pages: 2"))
        #expect(text.contains("rows: 3"))
        #expect(text.contains("states: 1×1 2×2"))
        #expect(text.contains("roles: 2×1 3×1 4×1"))
        #expect(text.contains("next_page_token on last page: false"))
        // A lowercase sentinel, so an uppercase-only masker could not pass this (CLAUDE.md).
        #expect(!text.contains("secret-id"))
        #expect(!text.contains("lowercase-token"))
    }
}
