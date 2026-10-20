import ChatKit
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct AccountOrganizationTests {
    @Test func anEmailAloneDoesNotClaimTheAccountIsManaged() {
        var user = User(); user.email = "alex@example.invalid"
        #expect(LocalBridgeBackend.organization(of: user) == .unstated)
        user.organizationInfo.consumerInfo = OrganizationInfo.ConsumerInfo()
        #expect(LocalBridgeBackend.organization(of: user) == .personal)
    }

    @Test func aStatedCustomerNeedsTheAccountsOwnEmailForItsDisplayDomain() {
        var user = User()
        user.organizationInfo.customerInfo = OrganizationInfo.CustomerInfo()
        #expect(LocalBridgeBackend.organization(of: user) == .unstated)
        user.email = "alex@EXAMPLE.invalid"
        #expect(LocalBridgeBackend.organization(of: user) == .managed(domain: "example.invalid"))
    }
}
