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

        @Test func recreatedCoordinatorsReuseFormattingAndImmutableResults() {
            let firstCoordinator = MessageTextView.Coordinator(message: message, actions: nil)
            let first = firstCoordinator.textCache.attributed(message: message, me: me, inOwnBubble: false)
            let secondCoordinator = MessageTextView.Coordinator(message: message, actions: nil)
            let second = secondCoordinator.textCache.attributed(message: message, me: me, inOwnBubble: false)
            #expect(first === second)
            #expect(!(first is NSMutableAttributedString))
        }

        @Test func fontAndAccentChangeFormattingAndAnEvictedValueIsRebuilt() {
            let cache = MessageTextCache(countLimit: 2)
            let first = cache.attributed(message: message, me: me, inOwnBubble: false)
            let larger = cache.attributed(
                message: message, me: me, inOwnBubble: false, font: .systemFont(ofSize: 30)
            )
            #expect((larger.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)?.pointSize == 30)
            let red = cache.attributed(message: message, me: me, inOwnBubble: false, accent: .red)
            #expect(red.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
                == NSColor.red.withAlphaComponent(0.25))
            let rebuilt = cache.attributed(message: message, me: me, inOwnBubble: false)
            #expect(first !== rebuilt)
            #expect(first.isEqual(to: rebuilt))
            #expect(cache.misses == 4)
            cache.removeAll()
            let cleared = cache.attributed(message: message, me: me, inOwnBubble: false)
            #expect(cleared !== rebuilt)
        }

        @Test func sessionAndPressureClearDropsSharedReusableWork() {
            let first = MessageTextCache.shared.attributed(message: message, me: me, inOwnBubble: false)
            let view = BubbleTextView.make()
            view.show(first)
            _ = view.fittingSize(forWidth: 293)
            MessageRenderingCache.clear()
            let second = MessageTextCache.shared.attributed(message: message, me: me, inOwnBubble: false)
            #expect(first !== second)
            #expect(first.isEqual(to: second))
            #expect(MessageTextCache.shared.misses == 1)
            #expect(MessageMeasurementCache.shared.hits == 0)
            let recreated = BubbleTextView.make()
            recreated.show(second)
            _ = recreated.fittingSize(forWidth: 293)
            #expect(MessageMeasurementCache.shared.hits == 0)
        }
    }
#endif
