import ChatAPI
import ChatKit
import ChatService
import Foundation
import Testing
@testable import ChatServiceStorage

struct InlineEmojiMediaTests {
    let emoji = CustomEmojiRef(id: "inline-emoji", shortcode: "parrot", imageToken: "issued-token")
    let conversation = Conversation.ID("chat")

    func message() -> Message {
        Message(
            id: .init("message"),
            conversationID: conversation,
            threadID: .init("thread"),
            sender: .init("sender"),
            text: emoji.displayText,
            createdAt: Date(timeIntervalSince1970: 10),
            content: MessageContent(customEmoji: [MessageCustomEmoji(
                emoji: emoji,
                start: 0,
                length: emoji.displayText.utf16
                    .count
            )])
        )
    }

    @Test func canonicalAndQueryEmojiAuthorityIsAccountScopedAndRevokesWithItsMessage() throws {
        let first = try SQLiteAccountStorage(account: .init("first"), path: ":memory:")
        let second = try SQLiteAccountStorage(account: .init("second"), path: ":memory:")
        let time = Date(timeIntervalSince1970: 100)
        try first.rememberQueryMedia([message()], at: time)
        let query = try #require(first.mediaSources(for: .customEmoji(emoji.id), at: time).first)
        #expect(try !first.isCurrentMediaSource(query, at: time.addingTimeInterval(900)))
        #expect(try second.mediaSources(for: .customEmoji(emoji.id), at: time).isEmpty)
        _ = try first.append(
            .conversationsChanged([Conversation(id: conversation, kind: .space)]),
            live: false
        )
        _ = try first.append(.messageReceived(message()), live: true)
        let canonical = try #require(first.mediaSources(for: .customEmoji(emoji.id), at: time).first)
        #expect(canonical.origin == .message(conversation, .init("message")))
        _ = try first.append(.messageDeleted(id: .init("message"), in: conversation), live: true)
        #expect(try !first.isCurrentMediaSource(canonical, at: time))
    }

    @Test func forwardedEmojiAuthorityBelongsToTheReceivingMessage() throws {
        let store = try SQLiteAccountStorage(account: .init("account"), path: ":memory:")
        _ = try store.append(
            .conversationsChanged([Conversation(id: conversation, kind: .space)]),
            live: false
        )
        var receiving = message()
        var source = MessageQuote(message: receiving)
        source.conversation = .init("inaccessible-source")
        source.id = .init("source-message")
        receiving.content = MessageContent(forwarded: ForwardedMessage(
            source: source,
            customEmoji: receiving.content?
                .customEmoji ?? []
        ))
        _ = try store.append(.messageReceived(receiving), live: true)
        let issued = try #require(store.mediaSources(for: .customEmoji(emoji.id), at: Date()).first)
        #expect(issued.origin == .message(conversation, receiving.id))
    }

    @Test func statusEmojiAuthorityFollowsTheCurrentMemberStatus() throws {
        let store = try SQLiteAccountStorage(account: .init("account"), path: ":memory:")
        let member = Member(
            id: .init("person"),
            kind: .human,
            displayName: "Person",
            status: MemberStatus(customEmoji: emoji)
        )
        _ = try store.append(.membersResolved([member]), live: false)
        let source = try #require(store.mediaSources(for: .customEmoji(emoji.id), at: Date()).first)
        #expect(source.origin == .member(member.id))
        _ = try store.append(.statusChanged(member: member.id, status: nil), live: true)
        #expect(try !store.isCurrentMediaSource(source, at: Date()))
    }
}
