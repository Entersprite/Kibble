import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `Conversation.readPosition`'s world-load source (the mentions-list spec §1).
struct WorldMappingReadPositionTests {
    private typealias Fixture = WorldItemFixture

    /// The read position differs from the head on purpose, so reading the
    /// wrong field goes red. It is off a millisecond, so a mapping that
    /// rounded would go red too.
    @Test func theTypedLastReadTimeBecomesTheReadPosition() {
        let item = Fixture.item(
            groupID: Fixture.dmGroupID("d-1"),
            lastReadMicros: 1_790_000_000_128_263, newestMessageMicros: 1_790_000_060_000_000
        )
        #expect(Fixture.mapped(item)?.readPosition == Microseconds.date(1_790_000_000_128_263))
    }

    /// Presence, not value. An absent `last_read_time` reads as `0` through
    /// the typed accessor, which would be 1970, a position that makes every
    /// mention read.
    @Test func anAbsentLastReadTimeIsNoReadPosition() {
        let item = Fixture.item(groupID: Fixture.dmGroupID("d-1"), newestMessageMicros: 1_790_000_060_000_000)
        #expect(Fixture.mapped(item)?.readPosition == nil)
    }
}
