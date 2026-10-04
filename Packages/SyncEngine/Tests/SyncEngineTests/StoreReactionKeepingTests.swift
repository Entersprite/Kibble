import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// A push is never the source of truth for reactions (reactions spec §2.2):
/// a repeated field has no presence, so "no field 21" and "no reactions" look
/// the same. History is authoritative; pushes keep what is stored.
struct StoreReactionKeepingTests {
    private let conversation = Conversation.ID("space/s-1")

    private func message(
        _ id: String,
        text: String = "hi",
        isDeleted: Bool = false,
        reactions: [Reaction] = [],
        localID: String? = nil
    )
        -> Message {
        Message(
            id: Message.ID(id), conversationID: conversation, threadID: MessageThread.ID("t-1"),
            sender: Member.ID("u-1"), text: text, createdAt: Date(timeIntervalSince1970: 1000),
            isDeleted: isDeleted, reactions: reactions, localID: localID
        )
    }

    private func stored(_ store: ChatStore, _ id: String) throws -> Message? {
        try store.messages(in: conversation).first { $0.id.rawValue == id }
    }

    private let thumbs = [Reaction(emoji: "👍", count: 2)]

    @Test func anEditPushKeepsTheReactions() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.upsertMessage(message("m-1", reactions: thumbs))])
        try store.apply([.upsertMessageKeepingReactions(message("m-1", text: "edited"))])
        let row = try #require(try stored(store, "m-1"))
        #expect(row.text == "edited")
        #expect(row.reactions == thumbs)
    }

    @Test func aPushForANewMessageWritesItsOwnReactions() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.upsertMessageKeepingReactions(message("m-2", reactions: thumbs))])
        #expect(try stored(store, "m-2")?.reactions == thumbs)
    }

    /// Fix round 1, Finding 1. The bridge maps no `messageDeleted`; a deletion
    /// arrives as `messageUpdated` with `isDeleted` set
    /// (`ChannelEventMapping.swift:143`), through this same case. Without the
    /// `!isDeleted` guard, a tombstone would keep its stored reactions and
    /// `MessageList` would draw live toggle buttons under "Message deleted".
    @Test func aDeletionPushDropsTheReactions() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.upsertMessage(message("m-1", reactions: thumbs))])
        try store.apply([.upsertMessageKeepingReactions(message("m-1", isDeleted: true))])
        let row = try #require(try stored(store, "m-1"))
        #expect(row.isDeleted)
        #expect(row.reactions == [])
    }

    /// Review Focus 1.
    @Test func aHistoryPageReplacesReactions() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.upsertMessage(message("m-1", reactions: thumbs))])
        try store.apply([.upsertMessage(message("m-1"))])
        #expect(try stored(store, "m-1")?.reactions == [])
    }

    /// Review Focus 3: the echo replaces the optimistic row by `localID`, and
    /// keeps only reactions stored under its own id. The optimistic row
    /// carries `thumbs` and the echo none, so a passing `reactions == []`
    /// proves the optimistic row's reactions do not carry over to the
    /// server id - not merely that both sides happened to be empty.
    @Test func theEchoOfASendStillReplacesTheOptimisticRow() throws {
        let store = try ChatStore.inMemory()
        try store.apply([.upsertMessage(message("local/l-1", reactions: thumbs, localID: "l-1"))])
        try store.apply([.upsertMessageKeepingReactions(message("m-real", localID: "l-1"))])
        let messages = try store.messages(in: conversation)
        #expect(messages.map(\.id.rawValue) == ["m-real"])
        #expect(messages.first?.reactions == [])
    }
}
