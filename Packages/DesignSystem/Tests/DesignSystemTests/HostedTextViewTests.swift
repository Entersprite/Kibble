#if os(macOS)
    import AppKit
    import ChatKit
    import Foundation
    import SwiftUI
    import Testing
    @testable import DesignSystem

    /// The text cursor shows over a message's text and the composer's field,
    /// and nowhere else: not between messages, and not through the search
    /// panel or the account panel drawn over them.
    @MainActor
    @Suite(.serialized)
    struct HostedTextViewTests {
        /// A message in the transcript's shape: a narrow bubble in a scroll
        /// view much larger than it, and a composer below.
        private struct Transcript: View {
            var covered = false
            @State private var draft: ComposerDraft = {
                var draft = ComposerDraft()
                draft.edit("Hello there")
                return draft
            }()

            var body: some View {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading) {
                            HStack {
                                MessageTextView(
                                    insets: NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12),
                                    message: Message(
                                        id: Message.ID("m-1"), conversationID: Conversation.ID("space/s-1"),
                                        threadID: MessageThread.ID("t-1"), sender: Member.ID("u-1"),
                                        text: "short", createdAt: Date(timeIntervalSince1970: 0)
                                    ),
                                    actions: nil
                                )
                                Spacer(minLength: 60)
                            }
                            Color.gray.frame(height: 600)
                        }
                    }
                    ComposerTextView(
                        draft: $draft, anchorX: .constant(0), listOpen: false, focusRequest: 0,
                        onKey: { _ in }, onSubmit: {}
                    )
                }
                .coveredByPanel(covered)
            }
        }

        private func host(covered: Bool = false) -> (NSWindow, NSHostingView<Transcript>) {
            let host = NSHostingView(rootView: Transcript(covered: covered))
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
            let window = NSWindow(
                contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            return (window, host)
        }

        private func find<View: NSView>(_: View.Type, in view: NSView) -> View? {
            if let found = view as? View {
                return found
            }
            return view.subviews.lazy.compactMap { find(View.self, in: $0) }.first
        }

        /// Over the first letters of either view's text.
        private let overText = NSPoint(x: 14, y: 12)

        private func cursorUpdate(over view: NSView, _ window: NSWindow) -> NSEvent? {
            NSEvent.enterExitEvent(
                with: .cursorUpdate, location: view.convert(overText, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                trackingNumber: 0, userData: nil
            )
        }

        /// AppKit gives a text view's text cursor to its visible rect. Unclipped
        /// in SwiftUI's container, a short message's was the whole scroll view.
        @Test func aMessageClaimsOnlyItsOwnText() throws {
            let (window, host) = host()
            defer { window.close() }
            let text = try #require(find(BubbleTextView.self, in: host))
            #expect(text.frame.width < 200)
            #expect(text.bounds.contains(text.visibleRect), "\(text.visibleRect) beyond \(text.bounds)")
        }

        /// The positive control: uncovered, the message and the field set the
        /// text cursor when the pointer reaches their text.
        @Test func uncoveredTextShowsTheTextCursor() throws {
            let (window, host) = host()
            defer { window.close() }
            let message = try #require(find(BubbleTextView.self, in: host))
            let field = try #require(find(ComposerNSTextView.self, in: host))
            for view in [message, field] as [HostedTextView] {
                #expect(view.showsTextCursor)
                NSCursor.arrow.set()
                try view.cursorUpdate(with: #require(cursorUpdate(over: view, window)))
                #expect(NSCursor.current == NSCursor.iBeam)
            }
        }

        /// Under a panel, neither the message nor the field sets the text
        /// cursor, also once the panel opens over text already shown. (A
        /// test window is never key, so `NSTextView` sets no cursor on a
        /// mouse move here at all; `HostedTextView.mouseMoved` is not
        /// reached by this test.)
        @Test func coveredTextShowsThePointer() throws {
            let (window, host) = host()
            defer { window.close() }
            host.rootView = Transcript(covered: true)
            host.layoutSubtreeIfNeeded()
            let message = try #require(find(BubbleTextView.self, in: host))
            let field = try #require(find(ComposerNSTextView.self, in: host))
            for view in [message, field] as [HostedTextView] {
                #expect(!view.showsTextCursor)
                NSCursor.arrow.set()
                try view.cursorUpdate(with: #require(cursorUpdate(over: view, window)))
                #expect(NSCursor.current != NSCursor.iBeam)
            }
            host.rootView = Transcript(covered: false)
            host.layoutSubtreeIfNeeded()
            #expect(message.showsTextCursor)
            #expect(field.showsTextCursor)
        }

        /// The window marks its content covered while the search panel is
        /// shown, and the account shell while its panel is open.
        @Test func theSearchPanelAndTheAccountPanelCoverTheTranscript() async throws {
            let conversation = Conversation(id: .init("space/s-1"), kind: .space, title: "Design")
            let message = Message(
                id: Message.ID("m-1"), conversationID: conversation.id, threadID: MessageThread.ID("t-1"),
                sender: Member.ID("u-1"), text: "short", createdAt: Date(timeIntervalSince1970: 0)
            )
            func window(search: Bool, accountPanel: Bool) -> some View {
                var state = ChatSceneState(
                    conversations: [conversation], selected: conversation.id, messages: [message],
                    capabilities: Capabilities(canSendMessages: true)
                )
                state.search.isShown = search
                return AccountShell(
                    state: AccountPanelState(accounts: [], selectedID: nil, scene: state),
                    actions: AccountPanelActions(select: { _ in }),
                    isPanelOpen: .constant(accountPanel)
                ) {
                    ChatWindow(state: state, actions: ChatSceneActions(search: .inert))
                }
                .frame(width: 900, height: 600)
            }
            for (search, accountPanel) in [(false, false), (true, false), (false, true)] {
                let host = NSHostingView(rootView: window(search: search, accountPanel: accountPanel))
                host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
                let shown = NSWindow(
                    contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false
                )
                shown.isReleasedWhenClosed = false
                shown.contentView = host
                defer { shown.close() }
                for _ in 0 ..< 10 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(20))
                }
                let text = try #require(find(BubbleTextView.self, in: host))
                let covered = search || accountPanel
                #expect(text.showsTextCursor == !covered, "search \(search), panel \(accountPanel)")
            }
        }

        /// A panel inside another keeps the outer one's cover: closing the
        /// search panel under the open account panel uncovers nothing.
        @Test func anInnerPanelKeepsTheOuterCover() throws {
            let host = NSHostingView(rootView: Transcript(covered: false).coveredByPanel(true))
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
            host.layoutSubtreeIfNeeded()
            let message = try #require(find(BubbleTextView.self, in: host))
            #expect(!message.showsTextCursor)
        }
    }
#endif
