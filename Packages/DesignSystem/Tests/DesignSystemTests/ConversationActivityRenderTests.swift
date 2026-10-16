#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    struct ConversationActivityRenderTests {
        @Test func renderRealActivityViewsAtNarrowAndRegularWidths() throws {
            let me = Member.ID("me")
            let alex = Member.ID("alex")
            let sam = Member.ID("sam")
            let conversation = Conversation(
                id: Conversation.ID("conversation"),
                kind: .groupDirectMessage,
                members: [me, alex, sam]
            )
            let members = [
                Member(id: me, kind: .human, displayName: "You"),
                Member(id: alex, kind: .human, displayName: "Alex"),
                Member(id: sam, kind: .human, displayName: "Sam")
            ]
            let directory = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
            let message = Message(
                id: Message.ID("message"),
                conversationID: conversation.id,
                threadID: MessageThread.ID("thread"),
                sender: me,
                text: "I'll bring the coffee.",
                createdAt: Date(timeIntervalSince1970: 100)
            )
            let state = ChatSceneState(
                conversations: [conversation],
                directory: directory,
                me: me,
                selected: conversation.id,
                messages: [message]
            )
            for width in [CGFloat(280), CGFloat(460)] {
                for dark in [false, true] {
                    let preview = VStack(alignment: .leading, spacing: 20) {
                        MessageBubble(
                            message: message,
                            state: MessageRowState(message: message, scene: state),
                            receiptDirectory: directory,
                            receiptReaders: [alex, sam],
                            receiptSlot: true,
                            groupReceipt: true
                        )
                        TypingIndicator(members: [alex, sam], directory: directory, namesVisible: true)
                    }
                    .padding(20).frame(width: width).background(.background)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    try snapshot(preview, width: width, dark: dark)
                }
            }
        }

        @Test func activityDoesNotMoveTheTranscriptWhileReadingHistory() throws {
            let me = Member.ID("me")
            let other = Member.ID("other")
            let conversation = Conversation(id: Conversation.ID("conversation"), kind: .directMessage)
            let messages = historyMessages(in: conversation.id, by: me)
            var state = ChatSceneState(
                conversations: [conversation],
                me: me,
                selected: conversation.id,
                messages: messages,
                capabilities: Capabilities(
                    receivesTypingState: true,
                    receivesReadReceipts: true
                )
            )
            let host = NSHostingView(rootView: MessageList(state: state).frame(width: 400, height: 300))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let scroll = try #require(findScroll(in: host))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
            scroll.reflectScrolledClipView(scroll.contentView)
            let origin = scroll.contentView.bounds.origin.y
            let viewport = scroll.contentView.bounds.height
            state.activity.typing = [TypingUpdate(
                conversationID: conversation.id,
                member: other,
                isTyping: true
            )]
            state.activity.receiptsEnabled = true
            state.activity.receipts = [ReadPosition(
                member: other,
                readThrough: Date(timeIntervalSince1970: 40)
            )]
            host.rootView = MessageList(state: state).frame(width: 400, height: 300)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            #expect(abs(scroll.contentView.bounds.origin.y - origin) <= 1)
            #expect(abs(scroll.contentView.bounds.height - viewport) <= 1)
            withExtendedLifetime(window) {}
        }

        private func historyMessages(in conversation: Conversation.ID, by me: Member.ID) -> [Message] {
            (0 ..< 40).map { index in
                Message(
                    id: Message.ID("message-\(index)"),
                    conversationID: conversation,
                    threadID: MessageThread.ID("thread-\(index)"),
                    sender: me,
                    text: "Message \(index)",
                    createdAt: Date(timeIntervalSince1970: Double(index))
                )
            }
        }

        private func findScroll(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView {
                return scroll
            }
            for child in view.subviews {
                if let scroll = findScroll(in: child) {
                    return scroll
                }
            }
            return nil
        }

        private func snapshot(_ preview: some View, width: CGFloat, dark: Bool) throws {
            let host = NSHostingView(rootView: preview)
            host.frame.size = host.fittingSize
            let window = NSWindow(
                contentRect: host.frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            window.contentView = host
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            #expect(host.frame.width == width)
            #expect(host.frame.height > 80)
            if let output = ProcessInfo.processInfo.environment["KIBBLE_ACTIVITY_RENDER_DIR"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
                let name = "activity-\(Int(width))-\(dark ? "dark" : "light").png"
                try bytes.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
            }
            withExtendedLifetime(window) {}
        }
    }
#endif
