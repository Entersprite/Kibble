import ChatKit
import Foundation

public struct AccountPolicy: Codable, Hashable, Sendable {
    public let revision: String
    public let settings: NotificationSettings

    public init(revision: String, settings: NotificationSettings) {
        self.revision = revision
        self.settings = settings
    }
}
