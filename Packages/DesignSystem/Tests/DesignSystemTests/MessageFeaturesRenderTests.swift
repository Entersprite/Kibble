#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    struct MessageFeaturesRenderTests {
        @Test func formattingQuotesMediaAndAppActionsRenderAtNarrowAndRegularWidths() throws {
            for width in [CGFloat(320), CGFloat(600)] {
                for dark in [false, true] {
                    let preview = content()
                        .padding(16).frame(width: width).background(.background)
                        .environment(\.colorScheme, dark ? .dark : .light)
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
                    #expect(host.frame.width == width)
                    #expect(host.frame.height > 300)
                    if let output = ProcessInfo.processInfo.environment["KIBBLE_MESSAGE_RENDER_DIR"] {
                        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let data = try #require(bitmap.representation(using: .png, properties: [:]))
                        try data
                            .write(to: URL(fileURLWithPath: output)
                                .appendingPathComponent(
                                    "messages-\(Int(width))-\(dark ? "dark" : "light").png"
                                ))
                    }
                    withExtendedLifetime(window) {}
                }
            }
        }

        private func content() -> some View {
            VStack(alignment: .leading, spacing: 16) {
                SearchFilterRow(query: MessageSearchQuery(text: "plan"), filters: [
                    .from, .conversation, .olderThan, .newerThan, .hasFile, .hasLink, .mentionsMe,
                    .newestFirst
                ], people: [], conversations: [], directory: [:], me: nil, setQuery: { _ in })
                row()
                AppCardView(
                    card: AppCard(
                        header: .init(title: RichText("Linear · Example issue")),
                        sections: [.init(widgets: [.text(RichText("Project plan needs review."))])],
                        actions: [AppCardAction(
                            id: "example",
                            label: "Acknowledge"
                        )]
                    ),
                    load: nil,
                    perform: { _ in AppCardActionResult() }
                )
                LinkPreviewCard(link: MessageLink(
                    url: URL(string: "https://example.test/document")!,
                    preview: LinkPreview(
                        title: "Project plan",
                        domain: "example.test",
                        presentation: "document"
                    )
                ), load: nil)
                MessageQuotePreview(quote: quote(), directory: [:], cancel: {})
            }
        }

        private func quote() -> MessageQuote {
            MessageQuote(message: Message(
                id: .init("original"),
                conversationID: .init("conversation"),
                threadID: .init("thread"),
                sender: .init("peer"),
                text: "Can you review the project plan?",
                createdAt: Date(timeIntervalSince1970: 1)
            ))
        }

        private func row() -> some View {
            let composed = MessageMarkup
                .parse(
                    ComposedMessage(
                        text: "**Bold**, *italic*, __underline__ and `code`.\n- First item\n- Second item"
                    )
                )
            let message = Message(
                id: .init("reply"),
                conversationID: .init("conversation"),
                threadID: .init("thread"),
                sender: .init("peer"),
                text: composed.text,
                createdAt: Date(timeIntervalSince1970: 2),
                content: MessageContent(formatting: composed.content?.formatting ?? [], quote: quote())
            )
            let scene = ChatSceneState(
                directory: [.init("peer"): Member(id: .init("peer"), kind: .human, displayName: "Taylor")],
                messages: [message]
            )
            return MessageBubble(message: message, state: MessageRowState(message: message, scene: scene))
        }
    }
#endif
