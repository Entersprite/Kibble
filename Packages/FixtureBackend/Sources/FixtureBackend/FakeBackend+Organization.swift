import ChatKit

extension FakeBackend: AccountOrganizationBackend {
    public func accountOrganization() async throws -> AccountOrganization {
        organization
    }
}
