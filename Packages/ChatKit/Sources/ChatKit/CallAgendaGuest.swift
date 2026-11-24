import Foundation

/// A Calendar invite shown in the current call's People panel.
public struct CallAgendaGuest: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let displayName: String
    public let response: String?
    public let isOptional: Bool
    public let chatAddress: String?

    public init(
        id: UUID, displayName: String, response: String? = nil, isOptional: Bool = false,
        chatAddress: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.response = response
        self.isOptional = isOptional
        self.chatAddress = chatAddress
    }
}
