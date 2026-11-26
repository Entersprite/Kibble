import Foundation

/// Optional provider port: who manages the signed-in account. A provider that
/// does not adopt it is treated as `.unstated`, and so is one that throws.
///
/// Asked once the provider has identified its own member, so an implementation
/// may answer from what its connection already learned. Display metadata only.
public protocol AccountOrganizationBackend: ChatBackend {
    func accountOrganization() async throws -> AccountOrganization
}
