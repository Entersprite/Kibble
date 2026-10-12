#if os(macOS)
    import AppKit
    import ChatKit
    import Testing
    @testable import DesignSystem

    @MainActor
    struct MessageTextCacheTests {
        private let me = Member.ID("me")
        private var message: Message {
            Message(
                id: Message.ID("message"), conversationID: Conversation.ID("space/example"),
                threadID: MessageThread.ID("thread"), sender: Member.ID("sender"),
                text: "@Me read this", createdAt: Date(timeIntervalSince1970: 100),
                mentions: [Mention(target: .user(me), start: 0, length: 3)]
            )
        }

        @Test func reactionUpdatesReuseFormattedTextAndPreserveSelection() {
            let cache = MessageTextCache()
            let first = cache.attributed(message: message, me: me, inOwnBubble: false)
            var reacted = message
            reacted.reactions = [Reaction(emoji: "👍", count: 1)]
            let second = cache.attributed(message: reacted, me: me, inOwnBubble: false)
            #expect(first === second)
            let view = BubbleTextView.make()
            view.show(first)
            view.setSelectedRange(NSRange(location: 4, length: 4))
            view.show(second)
            #expect(view.selectedRange() == NSRange(location: 4, length: 4))
        }

        @Test func editsAndChangedLinkTargetsReplaceCachedFormatting() throws {
            let cache = MessageTextCache()
            var edited = message
            let firstURL = try #require(URL(string: "https://example.com/first"))
            let secondURL = try #require(URL(string: "https://example.com/second"))
            edited.links = [MessageLink(url: firstURL, start: 9, length: 4)]
            let first = cache.attributed(message: edited, me: me, inOwnBubble: false)
            #expect(first.attribute(.link, at: 9, effectiveRange: nil) as? URL == firstURL)
            edited.links = [MessageLink(url: secondURL, start: 9, length: 4)]
            let second = cache.attributed(message: edited, me: me, inOwnBubble: false)
            #expect(second.attribute(.link, at: 9, effectiveRange: nil) as? URL == secondURL)
            edited.text = "Updated text"
            edited.mentions = []
            edited.links = []
            let third = cache.attributed(message: edited, me: me, inOwnBubble: false)
            #expect(third.string == "Updated text")
            #expect(third.attribute(.link, at: 9, effectiveRange: nil) == nil)
        }

        @Test func mentionIdentityAndBubbleColourRemainCurrent() {
            let cache = MessageTextCache()
            let unresolved = cache.attributed(message: message, me: nil, inOwnBubble: false)
            #expect(unresolved.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
            let resolved = cache.attributed(message: message, me: me, inOwnBubble: false)
            #expect(resolved.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
            let own = cache.attributed(message: message, me: me, inOwnBubble: true)
            #expect(own.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor == .white)
            #expect(own.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
            var unmentioned = message
            unmentioned.mentions = []
            let plain = cache.attributed(message: unmentioned, me: me, inOwnBubble: false)
            #expect(plain.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
        }
    }
#endif
