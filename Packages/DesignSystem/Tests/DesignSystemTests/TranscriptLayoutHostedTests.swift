#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// The text bubble's widest, and following a last row that grows, measured
    /// in a hosted transcript.
    @MainActor
    @Suite(.serialized)
    struct TranscriptLayoutHostedTests {
        private let conversation = Conversation.ID("hosted-layout")

        private func message(_ index: Int, text: String, reactions: [Reaction] = []) -> Message {
            Message(
                id: Message.ID("row-\(index)"), conversationID: conversation,
                threadID: MessageThread.ID("thread-\(index)"), sender: Member.ID("sender"), text: text,
                createdAt: Date(timeIntervalSince1970: Double(index) * 600), reactions: reactions
            )
        }

        private func texts(in view: NSView) -> [BubbleTextView] {
            (view as? BubbleTextView).map { [$0] } ?? view.subviews.flatMap(texts(in:))
        }

        private func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView {
                return scroll
            }
            return view.subviews.lazy.compactMap(scrollView(in:)).first
        }

        private func host(_ state: ChatSceneState, width: CGFloat) -> (NSWindow, NSHostingView<MessageList>) {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 380),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: MessageList(state: state))
            window.contentView = host
            window.orderFront(nil)
            window.displayIfNeeded()
            return (window, host)
        }

        private func settle(_ host: NSView, until condition: () -> Bool) async -> Bool {
            for _ in 0 ..< 100 {
                host.layoutSubtreeIfNeeded()
                if condition() {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        @Test(arguments: [(CGFloat(480), CGFloat(360)), (1000, 560)])
        func aLongMessageWrapsAtItsLimitAndAShortOneKeepsItsSize(
            width: CGFloat,
            limit: CGFloat
        ) async throws {
            let long = String(repeating: "A long message that wraps at the limit. ", count: 20)
            let state = ChatSceneState(
                selected: conversation, messages: [message(0, text: "Short"), message(1, text: long)]
            )
            let (window, host) = host(state, width: width)
            defer { window.close() }
            #expect(await settle(host) { texts(in: host).count == 2 })
            let short = try #require(texts(in: host).first { $0.string == "Short" })
            let wrapped = try #require(texts(in: host).first { $0.string == long })
            #expect(wrapped.frame.width <= limit)
            #expect(wrapped.frame.width > limit - 40, "the long text should reach about the limit")
            #expect(short.frame.width < 80)
        }

        /// A first reaction makes the newest row taller; read from the
        /// bottom, the transcript keeps the bottom in view.
        @Test func aGrowingLastRowIsFollowedFromTheBottom() async throws {
            var state = ChatSceneState(
                selected: conversation,
                messages: (0 ..< 40).map { message($0, text: "Message \($0): some words in a bubble") }
            )
            let (window, host) = host(state, width: 480)
            defer { window.close() }
            let scroll = try #require(scrollView(in: host))
            let atBottom = {
                guard let document = scroll.documentView else { return false }
                return document.frame.height - scroll.documentVisibleRect.maxY < 14
            }
            #expect(await settle(host) { (scroll.documentView?.frame.height ?? 0) > 1000 && atBottom() })
            let before = scroll.documentView?.frame.height ?? 0
            state.messages[39].reactions = [Reaction(emoji: "👍", count: 1)]
            state.messages[39].text += String(repeating: " and then the text grew longer", count: 12)
            host.rootView = MessageList(state: state)
            #expect(await settle(host) {
                (scroll.documentView?.frame.height ?? 0) > before + 60 && atBottom()
            })
        }

        /// Read from the middle, growth below leaves the reading position.
        @Test func aGrowingLastRowLeavesAReaderInTheMiddleAlone() async throws {
            var state = ChatSceneState(
                selected: conversation,
                messages: (0 ..< 40).map { message($0, text: "Message \($0): some words in a bubble") }
            )
            state.scrollTarget = Message.ID("row-10")
            let (window, host) = host(state, width: 480)
            defer { window.close() }
            let scroll = try #require(scrollView(in: host))
            #expect(await settle(host) { texts(in: host).contains { $0.string.hasPrefix("Message 10:") } })
            let origin = scroll.documentVisibleRect.minY
            state.messages[39].text += String(repeating: " and then the text grew longer", count: 12)
            host.rootView = MessageList(state: state)
            _ = await settle(host) { false }
            #expect(abs(scroll.documentVisibleRect.minY - origin) < 2)
        }
    }
#endif
