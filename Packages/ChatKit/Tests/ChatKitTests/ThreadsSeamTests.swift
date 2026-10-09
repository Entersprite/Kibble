import Foundation
import Testing
@testable import ChatKit

/// The threads seam (threads spec §1): each addition pinned to a golden file,
/// and each missing key decoding to "no" or "nobody has said", so a frame
/// from before threads means what it meant then.
@Suite("Threads seam")
struct ThreadsSeamTests {
    // MARK: - Models

    @Test("a reply, a full thread and a conversation with replies match their golden files")
    func modelGoldens() throws {
        try expectWireStable(Fixture.reply, golden: "message-reply")
        try expectWireStable(Fixture.threadFull, golden: "thread-full")
        try expectWireStable(Fixture.conversationWithReplies, golden: "conversation-replies")
    }

    /// Guard: `isReply` is written only when true. Delete the `if isReply`
    /// in `Message.encode(to:)` and this fails, with `message.json` beside it.
    @Test("a message that is not a reply writes no isReply key, and a missing key reads as false")
    func isReplyIsOmittedWhenFalse() throws {
        let json = try Wire.json(Fixture.message)
        #expect(!json.contains("isReply"))
        #expect(try Wire.decode(Message.self, from: json).isReply == false)
    }

    @Test("a thread from before threads decodes with nothing known")
    func bareThreadDefaults() throws {
        let json = #"{"conversationID":"space:1","id":"t-1","replyCount":2}"#
        let thread = try Wire.decode(MessageThread.self, from: json)
        #expect(thread.isFollowed == nil)
        #expect(thread.readPosition == nil)
        #expect(thread.markedUnreadAt == nil)
        #expect(thread.unreadCount == nil)
        #expect(thread.recentRepliers.isEmpty)
        #expect(thread.hasUnread == false)
    }

    /// `nil` is "nobody has said"; `false` is an answer and must survive.
    @Test("an unfollowed thread keeps its false")
    func unfollowedSurvives() throws {
        var thread = Fixture.thread
        thread.isFollowed = false
        let json = try Wire.json(thread)
        #expect(json.contains(#""isFollowed":false"#))
        #expect(try Wire.decode(MessageThread.self, from: json).isFollowed == false)
    }

    @Test("a conversation from before threads has replies off and no unread thread")
    func conversationDefaults() throws {
        let bare = try Wire.decode(Conversation.self, from: #"{"id":"dm:1","kind":"directMessage"}"#)
        #expect(bare.repliesEnabled == false)
        #expect(bare.hasUnreadThread == false)
        let json = try Wire.json(Fixture.dm)
        #expect(!json.contains("repliesEnabled"))
        #expect(!json.contains("hasUnreadThread"))
    }

    // MARK: - Events

    /// `.counted` is `Fixture.events`' sample; the rest are pinned here.
    @Test("every other thread change matches its golden file")
    func threadChangeGoldens() throws {
        try expectWireStable(changed(.read(upTo: Fixture.readAt)), golden: "event-threadChanged-read")
        try expectWireStable(
            changed(.markedUnread(at: Fixture.createdAt)),
            golden: "event-threadChanged-markedUnread"
        )
        try expectWireStable(
            changed(.markedUnread(at: nil)),
            golden: "event-threadChanged-markedUnread-cleared"
        )
        try expectWireStable(changed(.followed(true)), golden: "event-threadChanged-followed")
        try expectWireStable(changed(Fixture.unknownThreadChange), golden: "event-threadChanged-unknown")
    }

    @Test("a count the source does not give is omitted, never null")
    func unreadIsOmittedWhenUnknown() throws {
        let json = try Wire.json(ThreadChange.counted(messages: 3, unread: nil))
        #expect(json == #"{"messages":3,"type":"counted"}"#)
        #expect(try Wire.decode(ThreadChange.self, from: json) == .counted(messages: 3, unread: nil))
    }

    /// A newer backend's thread fact survives this build, and so does the
    /// event around it.
    @Test("an unknown thread change decodes and re-encodes verbatim")
    func unknownChangeRoundTrips() throws {
        let json = #"{"pinnedBy":"users/1001","type":"pinned"}"#
        let decoded = try Wire.decode(ThreadChange.self, from: json)
        #expect(decoded == Fixture.unknownThreadChange)
        #expect(try Wire.json(decoded) == json)
    }

    // MARK: - Commands

    @Test("clearing a thread's unread mark is the command with its at omitted")
    func clearedUnreadMark() throws {
        let cleared = ChatCommand.setThreadUnreadMark(
            conversationID: Fixture.spaceID, threadID: Fixture.threadID, at: nil
        )
        try expectWireStable(cleared, golden: "command-setThreadUnreadMark-cleared")
    }

    private func changed(_ change: ThreadChange) -> ChatEvent {
        .threadChanged(threadID: Fixture.threadID, conversationID: Fixture.spaceID, change: change)
    }
}
