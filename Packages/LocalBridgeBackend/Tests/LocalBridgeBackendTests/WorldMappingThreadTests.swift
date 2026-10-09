import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// World field 27 is the per-conversation gate, and read state 25 says a
/// conversation has an unread thread (threads spec §1, `findings.md` §63.2).
struct WorldMappingThreadTests {
    @Test func fieldTwentySevenEnablesReplies() throws {
        var item = WorldItemFixture.item(groupID: WorldItemFixture.spaceGroupID("s-1"), roomName: "Deploys")
        item.inlineThreadingEnabled = true
        #expect(try #require(WorldItemFixture.mapped(item)).repliesEnabled)
    }

    /// Meet chats send false (§63.2); an absent field is false too.
    @Test func falseOrAbsentDoesNot() throws {
        let absent = WorldItemFixture.item(groupID: WorldItemFixture.spaceGroupID("s-1"), roomName: "Deploys")
        var off = absent
        off.inlineThreadingEnabled = false
        #expect(try !#require(WorldItemFixture.mapped(absent)).repliesEnabled)
        #expect(try !#require(WorldItemFixture.mapped(off)).repliesEnabled)
    }

    @Test func readStateTwentyFiveIsAnUnreadThread() throws {
        var item = WorldItemFixture.item(groupID: WorldItemFixture.spaceGroupID("s-1"), roomName: "Deploys")
        item.readState.hasUnreadThread_p = true
        #expect(try #require(WorldItemFixture.mapped(item)).hasUnreadThread)
    }
}
