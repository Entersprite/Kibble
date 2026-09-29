import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// `--backend=fixture`'s path, end to end below the app. The demo world's
/// first connect pushes its world with no gap (ruling 7), the backfill runs
/// on the world's own clock (ruling 8), and both demo mentions reach the list.
@Suite(.timeLimit(.minutes(1)))
struct FixtureMentionsTests {
    @Test func theDemoWorldsTwoMentionsReachTheList() async throws {
        let world = FixtureWorld.acme
        let startedAt = world.startedAt
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: FakeBackend(world: world), store: store, mentionClock: { startedAt })
        try await engine.start()
        var found: [MentionOfMe] = []
        for _ in 0 ..< 400 where found.count < 2 {
            try await Task.sleep(for: .milliseconds(5))
            found = try store.mentionsOfMe()
        }
        #expect(found.map(\.message.id.rawValue).sorted() == ["msg:pe-mention", "msg:sw-all"])
        #expect(try store.unreadMentionCount() == 2)
        await engine.stop()
    }
}
