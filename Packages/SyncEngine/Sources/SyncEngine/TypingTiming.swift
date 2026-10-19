import ChatPersistence
import Foundation

public struct TypingTiming: Sendable {
    public var expiry: Duration
    public var idle: Duration
    public var renewal: Duration

    public init(
        expiry: Duration = .seconds(6),
        idle: Duration = .seconds(4),
        renewal: Duration = .seconds(3)
    ) {
        self.expiry = expiry
        self.idle = idle
        self.renewal = renewal
    }
}
