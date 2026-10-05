#if os(macOS)
    import AppKit
    import ChatKit
    import Foundation
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// `MessageTextView` placed by SwiftUI in an `NSHostingView`, in the
    /// transcript's shape (a scroll view, a lazy stack, a row with a spacer).
    /// The unit tests measure views nobody has laid out; these measure what
    /// SwiftUI actually gives the bubble (review fixes: Critical 1, Important 2).
    @MainActor
    struct MessageTextViewHostedTests {
        private struct Row: View {
            let text: String
            var body: some View {
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        HStack {
                            MessageTextView(
                                text: MentionAttributes.attributed(
                                    text,
                                    mentions: [],
                                    me: nil,
                                    inOwnBubble: false
                                ),
                                insets: NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12),
                                message: Message(
                                    id: Message.ID("m-1"), conversationID: Conversation.ID("space/s-1"),
                                    threadID: MessageThread.ID("t-1"), sender: Member.ID("u-1"), text: text,
                                    createdAt: Date(timeIntervalSince1970: 0)
                                ),
                                actions: ReactionActions { _, _, _ in }
                            )
                            Spacer(minLength: 60)
                        }
                    }
                }
            }
        }

        private static func host(_ text: String, width: CGFloat) -> NSHostingView<Row> {
            let host = NSHostingView(rootView: Row(text: text))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
            host.layoutSubtreeIfNeeded()
            return host
        }

        private static func textView(in view: NSView) -> BubbleTextView? {
            if let found = view as? BubbleTextView {
                return found
            }
            return view.subviews.lazy.compactMap(textView(in:)).first
        }

        private static func resize(_ host: NSHostingView<Row>, to width: CGFloat) {
            host.frame.size.width = width
            host.layoutSubtreeIfNeeded()
        }

        /// The bubble fits its text, and the text fits the bubble.
        private static func expectFits(
            _ view: BubbleTextView,
            sourceLocation: SourceLocation = #_sourceLocation
        ) {
            let needed = view.fittingSize(forWidth: view.frame.width)
            #expect(view.frame.height >= needed.height - 0.5, "clipped", sourceLocation: sourceLocation)
            #expect(
                view.frame.width <= needed.width + 0.5,
                "wider than its text",
                sourceLocation: sourceLocation
            )
        }

        @Test func aShortMessageIsAShortBubble() throws {
            let view = try #require(Self.textView(in: Self.host("short", width: 400)))
            #expect(view.frame.width < 100)
            Self.expectFits(view)
        }

        @Test func longTextNeverClipsAcrossResizes() throws {
            let long = String(repeating: "wrapping words ", count: 20)
            let host = Self.host(long, width: 400)
            let view = try #require(Self.textView(in: host))
            Self.expectFits(view)
            Self.resize(host, to: 220)
            Self.expectFits(view)
            Self.resize(host, to: 560)
            Self.expectFits(view)
            #expect(view.frame.width > 220)
        }

        /// Important 2: the feature is the delegate. Without it the native
        /// menu has no reactions, and every other test still passes.
        @Test func theHostedViewsMenuCarriesTheReactions() throws {
            let view = try #require(Self.textView(in: Self.host("hello there", width: 400)))
            #expect(view.delegate is MessageTextView.Coordinator)
            let event = try #require(NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: 20, y: 10), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            let menu = try #require(view.menu(for: event))
            #expect(menu.items.first?.submenu?.presentationStyle == .palette)
        }
    }
#endif
