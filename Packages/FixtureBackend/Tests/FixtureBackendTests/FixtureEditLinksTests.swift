import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

/// Review finding 1: the fixture's edit echo drops links anchored in the old
/// text, as the client's optimistic copy does, and keeps unanchored ones.
struct FixtureEditLinksTests {
    @Test func anEditDropsLinksAnchoredInTheOldText() async throws {
        let backend = FakeBackend(world: .acme)
        try await backend.connect()
        let id = Message.ID("msg:fd-3")
        try await backend.send(.editMessage(id: id, text: "a much longer text than the link was in"))
        let edited = try #require(try await backend.loadMessages(in: Acme.catalog, before: nil)
            .first { $0.id == id })
        #expect(edited.links.allSatisfy { $0.start == nil })
        #expect(edited.links.isEmpty)
    }
}
