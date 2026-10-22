#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    @Suite(.serialized)
    struct TranscriptJumpLayoutTests {
        private func state() -> ChatSceneState {
            let conversation = Conversation.ID("jump-layout")
            let sender = Member.ID("alex")
            var state = ChatSceneState(
                selected: conversation,
                messages: (0 ..< 40).map { index in
                    Message(
                        id: Message.ID("row-\(index)"), conversationID: conversation,
                        threadID: MessageThread.ID("thread-\(index)"), sender: sender,
                        text: "Message \(index): some words in a bubble",
                        createdAt: Date(timeIntervalSince1970: Double(index) * 600)
                    )
                },
                capabilities: Capabilities(receivesTypingState: true)
            )
            state.directory[sender] = Member(id: sender, kind: .human, displayName: "Alex")
            state.activity.typing = [TypingUpdate(
                conversationID: conversation,
                member: sender,
                isTyping: true
            )]
            return state
        }

        @Test func theJumpUsesTheTypingRowAboveTheComposer() async throws {
            let harness = TranscriptFollowHostedTests.Harness(state())
            defer { harness.close() }
            await harness.settle()
            #expect(harness.jump == nil)
            #expect(harness.labelled("Alex is typing…") != nil, "typing is shown while following")
            let scroll = try #require(harness.scroll)
            let bottomInset = scroll.contentInsets.bottom
            let viewport = scroll.contentView.bounds.size

            try await harness.wheel(40)
            let jump = try #require(harness.jump)
            let frame = try #require(harness.accessibilityFrame(jump))
            let composerTop = harness.window.convertPoint(toScreen: NSPoint(x: 0, y: harness.composer)).y
            #expect(abs(frame.minY - composerTop - TranscriptJumpOverlay.gap) < 1)
            #expect(harness.labelled("Alex is typing…") == nil, "typing must not overlap the jump")
            #expect(scroll.contentInsets.bottom == bottomInset)
            #expect(scroll.contentView.bounds.size == viewport)

            // Loading temporarily hides the jump. Typing may use the same
            // slot again without changing the viewport or the reading row.
            let row = try #require(harness.visibleRow)
            let position = try #require(harness.frame(of: row)?.minY)
            harness.state.isLoadingOlderMessages = true
            harness.show()
            await harness.settle()
            #expect(harness.jump == nil)
            #expect(harness.labelled("Alex is typing…") != nil)
            #expect(scroll.contentInsets.bottom == bottomInset)
            #expect(scroll.contentView.bounds.size == viewport)
            #expect(try abs(#require(harness.frame(of: row)?.minY) - position) < 2)
        }
    }
#endif
