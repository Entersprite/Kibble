import ChatKit
import Foundation

/// What the service last learned about a connected account's own identity, so
/// a client can show every account, including a disabled or signed-out one.
///
/// Display metadata only: never an authorization or storage key. Every field
/// is optional on the wire, and an absent organization reads as `.unstated`.
public struct AccountProfile: Codable, Hashable, Sendable {
    public let displayName: String?
    public let email: String?
    public let organization: AccountOrganization

    /// The longest name or email kept, in UTF-8 bytes; longer values are dropped.
    public static let maximumFieldBytes = 512

    public init(displayName: String?, email: String?, organization: AccountOrganization = .unstated) {
        self.displayName = displayName.flatMap(Self.bounded)
        self.email = email.flatMap(Self.bounded)
        self.organization = Self.bounded(organization)
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, email, organization
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            displayName: values.decodeIfPresent(String.self, forKey: .displayName),
            email: values.decodeIfPresent(String.self, forKey: .email),
            organization: values.decodeIfPresent(AccountOrganization.self, forKey: .organization) ?? .unstated
        )
    }

    private static func bounded(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.utf8.count > maximumFieldBytes ? nil : trimmed
    }

    private static func bounded(_ organization: AccountOrganization) -> AccountOrganization {
        guard case let .managed(domain) = organization else { return organization }
        return bounded(domain).map { .managed(domain: $0) } ?? .unstated
    }
}
