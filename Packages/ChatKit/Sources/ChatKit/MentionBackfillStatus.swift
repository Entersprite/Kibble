import Foundation

public struct MentionBackfillStatus: Codable, Hashable, Sendable {
    public var running: Bool
    public var failedConversations: Int

    public init(running: Bool = false, failedConversations: Int = 0) {
        self.running = running
        self.failedConversations = failedConversations
    }
}
