import ChatKit
import Foundation

/// A cursor acknowledges the ordered commit containing this event.
public struct ServiceEvent: Codable, Hashable, Sendable {
    public let cursor: ServiceCursor
    public let event: ChatEvent
    public let isLiveArrival: Bool

    public init(cursor: ServiceCursor, event: ChatEvent, isLiveArrival: Bool) {
        self.cursor = cursor
        self.event = event
        self.isLiveArrival = isLiveArrival
    }
}

/// A replacement snapshot and its checkpoint must come from the same transaction.
/// Message histories are fetched lazily; resync invalidates their old coverage.
public struct ServiceEventPage: Codable, Hashable, Sendable {
    public let checkpoint: ServiceCursor
    public let snapshot: [ChatEvent]?
    public let events: [ServiceEvent]
    public let hasMore: Bool

    public init(checkpoint: ServiceCursor, snapshot: [ChatEvent]?, events: [ServiceEvent], hasMore: Bool) {
        self.checkpoint = checkpoint
        self.snapshot = snapshot
        self.events = events
        self.hasMore = hasMore
    }
}
