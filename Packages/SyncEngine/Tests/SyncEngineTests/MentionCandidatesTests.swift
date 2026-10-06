import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// Who the `@` list offers (mention composer spec §3.3): the conversation's
/// members minus you and apps, the most recent senders first, then by name;
/// past senders when the conversation lists nobody yet.
struct MentionCandidatesTests {
    private let space = Conversation.ID("space/s-1")
    private let me = Member.ID("me")

    private func human(_ id: String, _ name: String?) -> Member {
        Member(id: Member.ID(id), kind: .human, displayName: name, email: "\(id)@example.invalid")
    }

    private func message(_ id: String, from sender: String, at seconds: Double) -> Message {
        Message(
            id: Message.ID(id), conversationID: space, threadID: MessageThread.ID("t"),
            sender: Member.ID(sender), text: "x", createdAt: Date(timeIntervalSince1970: seconds)
        )
    }

    private func store(members: [Member], listed: [String], messages: [Message]) throws -> ChatStore {
        let store = try ChatStore.inMemory()
        try store.apply([.upsertConversation(Conversation(id: space, kind: .space))])
        try store.apply([.upsertMembers(members)])
        if !listed.isEmpty {
            try store.apply([.setMembership(conversation: space, members: listed.map { Member.ID($0) })])
        }
        try store.apply(messages.map { .upsertMessage($0) })
        try store.apply([.setLocalMember(me)])
        return store
    }

    @Test func recentSendersComeFirstThenByName() throws {
        let store = try store(
            members: [human("me", "Me"), human("a", "Zed"), human("b", "Amy"), human("c", "Bo")],
            listed: ["me", "a", "b", "c"],
            messages: [message("m1", from: "c", at: 1), message("m2", from: "a", at: 2)]
        )
        #expect(try store.mentionCandidates(in: space).map(\.id.rawValue) == ["a", "c", "b"])
    }

    @Test func appsAndNamelessPeopleAreLeftOut() throws {
        let bot = Member(id: Member.ID("bot"), kind: .app, displayName: "Bot")
        let store = try store(
            members: [human("a", "Amy"), human("n", nil), bot], listed: ["a", "n", "bot"], messages: []
        )
        #expect(try store.mentionCandidates(in: space).map(\.id.rawValue) == ["a"])
    }

    @Test func withNoMembershipTheSendersStandIn() throws {
        let store = try store(
            members: [human("a", "Amy"), human("b", "Bo")], listed: [],
            messages: [message("m1", from: "b", at: 1)]
        )
        #expect(try store.mentionCandidates(in: space).map(\.id.rawValue) == ["b"])
    }
}
