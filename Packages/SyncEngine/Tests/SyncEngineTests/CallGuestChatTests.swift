import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CallGuestChatTests {
    private let guest = Member(id: Member.ID("guest"), kind: .human, email: "guest@example.test")

    @Test func anExactAddressOpensTheDirectConversationWithoutSending() async throws {
        let prefix = Member(id: Member.ID("prefix"), kind: .human, email: "guest@example.test.invalid")
        let backend = RecordingBackend(directory: [prefix, guest])
        let model = try await SearchModelTests.model(backend)
        try await model.openCallGuestChat(to: "Guest@EXAMPLE.TEST") { true }
        let conversation = try #require(try model.store.conversations().first { $0.id == model.selected })
        #expect(conversation.kind == .directMessage)
        #expect(conversation.members.contains(guest.id) && !conversation.members.contains(prefix.id))
        #expect(try model.store.messages(in: conversation.id).isEmpty)
        #expect(await backend.searches == ["Guest@EXAMPLE.TEST"])
        await model.stop()
    }

    @Test func twoPeopleWithTheSameAddressLeaveTheConversationUnopened() async throws {
        let duplicate = Member(id: Member.ID("duplicate"), kind: .human, email: guest.email)
        let backend = RecordingBackend(directory: [duplicate, guest])
        let model = try await SearchModelTests.model(backend)
        await #expect(throws: ChatError.self) {
            try await model.openCallGuestChat(to: "guest@example.test") { true }
        }
        #expect(model.selected == nil)
        #expect(try await backend.loadConversations().allSatisfy { !$0.members.contains(guest.id) })
        await model.stop()
    }

    @Test func aRetiredGuestLookupCannotOpenAConversation() async throws {
        let backend = RecordingBackend(directory: [guest])
        await backend.holdSearches(true)
        let model = try await SearchModelTests.model(backend)
        var current = true
        let pending = Task { try await model.openCallGuestChat(to: "guest@example.test") { current } }
        await settleAutoMarkRead(until: "Guest lookup starts") { await backend.heldSearchCount == 1 }
        current = false
        await backend.releaseHeldSearch()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(model.selected == nil)
        #expect(try await backend.loadConversations().allSatisfy { !$0.members.contains(guest.id) })
        await model.stop()
    }
}
