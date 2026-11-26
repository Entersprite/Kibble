import Foundation

/// Omitted fields are preserved. Empty strings explicitly clear optional content.
public struct ConversationDetailsPatch: Codable, Hashable, Sendable {
    public var name: String?
    public var description: String?
    public var guidelines: String?
    public var emoji: String?

    public init(
        name: String? = nil,
        description: String? = nil,
        guidelines: String? = nil,
        emoji: String? = nil
    ) {
        self.name = name; self.description = description; self.guidelines = guidelines; self.emoji = emoji
    }
}
