import ChatKit
import Foundation
import GChatBridgeCore

/// Who manages the signed-in account, as Chat states it in the account's own
/// `User` (`organization_info`, field 12): a consumer, or a customer, which is
/// Google's word for an organization.
extension LocalBridgeBackend: AccountOrganizationBackend {
    public func accountOrganization() async throws -> AccountOrganization {
        selfOrganization
    }

    func noteOwnOrganization(in response: GetMembersResponse) {
        guard let me = calendarPoll.me,
              let user = response.members.map(\.user).first(where: { $0.userID.id == me.rawValue })
        else { return }
        selfOrganization = Self.organization(of: user)
    }

    /// Chat sends a customer's id, never its name, so a customer is shown by
    /// the domain of the account's own email: the domain the organization
    /// signs its people in with. An account that states neither kind, or a
    /// customer without an email, is `.unstated`.
    static func organization(of user: User) -> AccountOrganization {
        guard user.hasOrganizationInfo else { return .unstated }
        let info = user.organizationInfo
        if info.hasCustomerInfo {
            guard let at = user.email.lastIndex(of: "@") else { return .unstated }
            let domain = user.email[user.email.index(after: at)...].lowercased()
            return domain.isEmpty ? .unstated : .managed(domain: domain)
        }
        return info.hasConsumerInfo ? .personal : .unstated
    }
}
