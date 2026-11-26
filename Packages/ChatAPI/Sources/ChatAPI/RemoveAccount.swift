import ChatKit
import Foundation

public struct RemoveAccount: ServiceRequestPayload {
    public typealias Response = ServiceUnit
    public static let operation = "removeAccount"
    public static let requiresAccount = true

    /// Also forgets the settings kept for the account's identity: its
    /// notification and privacy policy. Missing on the wire means `false`, an
    /// older client's removal, which keeps them for adding the account again.
    public let forgetsSettings: Bool

    public init(forgetsSettings: Bool = false) {
        self.forgetsSettings = forgetsSettings
    }

    private enum CodingKeys: String, CodingKey {
        case forgetsSettings
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        forgetsSettings = try values.decodeIfPresent(Bool.self, forKey: .forgetsSettings) ?? false
    }
}

/// Signs the account out on this Mac and keeps it: its credentials and this
/// Mac's copy of its conversations are erased, its settings stay, and it waits
/// in `authenticationState` "required" until it is signed in again as the same
/// identity. Already signed out returns the account as it is.
public struct SignOutAccount: ServiceRequestPayload {
    public typealias Response = AccountSummary
    public static let operation = "signOutAccount"
    public static let requiresAccount = true

    public init() {}
}
