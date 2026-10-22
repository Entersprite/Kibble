#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    struct QuotePresentationTests {
        private let me = Member.ID("me")
        private let alex = Member.ID("alex")

        private var directory: [Member.ID: Member] {
            [
                me: Member(id: me, kind: .human, displayName: "Sam Example"),
                alex: Member(id: alex, kind: .human, displayName: "Alex Example")
            ]
        }

        @Test func quoteNamesItsAuthorYouOrNobody() {
            let quoted = quote(from: alex, text: "Original")
            #expect(MessageQuotePreview.author(of: quoted, directory: directory, me: me) == "Alex Example")
            let mine = quote(from: me, text: "Mine")
            #expect(MessageQuotePreview.author(of: mine, directory: directory, me: me) == "Sam Example")
            #expect(MessageQuotePreview.author(of: mine, directory: [:], me: me) == "You")
            #expect(MessageQuotePreview.author(of: quoted, directory: [:], me: me) == nil)
            #expect(MessageQuotePreview.author(
                of: quote(from: Member.ID(""), text: "x"),
                directory: [:],
                me: me
            )
                == nil)
        }

        /// A row's directory carries the quoted author, or the quote could
        /// not name someone the transcript knows.
        @Test func rowDirectoryCarriesTheQuotedAuthor() {
            let reply = reply(from: me, quoting: quote(from: alex, text: "Original"))
            let state = MessageRowState(message: reply, scene: ChatSceneState(directory: directory, me: me))
            #expect(state.directory[alex]?.displayName == "Alex Example")
        }

        /// Above a reply the quote is as wide as its words, and never wider
        /// than a text bubble; the composer's reply spans its column.
        @Test func quoteFitsItsWordsUpToABubblesWidest() {
            let short = width(of: BubbleWidthLimit(reserve: MessageBubbleLayout.reserve(isMine: false)) {
                MessageQuotePreview(quote: quote(from: alex, text: "Short"), directory: directory, me: me)
            }, offered: 1000)
            #expect(short < 200)
            let long = width(of: BubbleWidthLimit(reserve: MessageBubbleLayout.reserve(isMine: false)) {
                MessageQuotePreview(
                    quote: quote(from: alex, text: String(repeating: "A long quoted line. ", count: 30)),
                    directory: directory, me: me
                )
            }, offered: 1000)
            #expect(long <= MessageBubbleLayout.maxTextWidth)
            #expect(long > 400)
            let composer = width(
                of: MessageQuotePreview(
                    quote: quote(from: alex, text: "Short"),
                    directory: directory,
                    cancel: {}
                ),
                offered: 700
            )
            #expect(composer == 700)
        }

        @Test func quotedRepliesRender() throws {
            for dark in [false, true] {
                var incoming = reply(from: alex, quoting: quote(
                    from: me,
                    text: "@Taylor one more for the deployment: the staging change, with the steps noted."
                ), text: "1. it's fine as you did it\n2. assess based on expected traffic")
                incoming.reactions = [Reaction(emoji: "👍", count: 1, includesMe: true)]
                var outgoing = reply(from: me, quoting: quote(from: me, text: "Test"), text: "yo")
                outgoing.reactions = [Reaction(emoji: "👍", count: 1, includesMe: false)]
                let unknown = reply(
                    from: me,
                    quoting: quote(from: Member.ID("stranger"), text: "Who said this")
                )
                let scene = ChatSceneState(
                    directory: directory,
                    me: me,
                    messages: [incoming, outgoing, unknown]
                )
                let preview = VStack(spacing: 12) {
                    MessageBubble(message: incoming, state: MessageRowState(message: incoming, scene: scene))
                    MessageBubble(message: outgoing, state: MessageRowState(message: outgoing, scene: scene))
                    MessageBubble(message: unknown, state: MessageRowState(message: unknown, scene: scene))
                    MessageQuotePreview(
                        quote: quote(from: alex, text: "Composer reply"),
                        directory: directory,
                        me: me,
                        cancel: {}
                    )
                }
                .padding(16).frame(width: 900).background(.background)
                .environment(\.colorScheme, dark ? .dark : .light)
                try render(preview, name: "quotes-\(dark ? "dark" : "light")", dark: dark)
            }
        }

        private func width(of view: some View, offered: CGFloat) -> CGFloat {
            NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: offered, height: 2000)).width
        }

        private func quote(from sender: Member.ID, text: String) -> MessageQuote {
            MessageQuote(message: Message(
                id: .init("original-\(sender.rawValue)"), conversationID: .init("chat"),
                threadID: .init("original-\(sender.rawValue)"), sender: sender, text: text,
                createdAt: Date(timeIntervalSince1970: 1)
            ))
        }

        private func reply(from sender: Member.ID, quoting quote: MessageQuote, text: String = "Reply")
            -> Message {
            Message(
                id: .init("reply-\(sender.rawValue)-\(quote.sender.rawValue)"), conversationID: .init("chat"),
                threadID: .init("reply"), sender: sender, text: text,
                createdAt: Date(timeIntervalSince1970: 2),
                content: MessageContent(quote: quote)
            )
        }

        private func render(_ view: some View, name: String, dark: Bool) throws {
            guard let output = ProcessInfo.processInfo.environment["KIBBLE_MESSAGE_RENDER_DIR"]
            else { return }
            let host = NSHostingView(rootView: view)
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
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name).png"))
            withExtendedLifetime(window) {}
        }
    }
#endif
