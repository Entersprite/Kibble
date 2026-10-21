#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    struct OutgoingForwardUITests {
        private func message() -> Message {
            Message(
                id: .init("source"),
                conversationID: .init("source-chat"),
                threadID: .init("thread"),
                sender: .init("peer"),
                text: "Can you review the project plan?",
                createdAt: Date(timeIntervalSince1970: 1)
            )
        }

        @Test func forwardedMessagesOfferTheNativeMenuActionButDeletedAndPendingMessagesDoNot() throws {
            var original = message()
            original
                .content =
                MessageContent(forwarded: ForwardedMessage(source: MessageQuote(message: original)))
            var chosen: Message.ID?
            let handlers = OwnMessageHandlers(forward: { chosen = $0.id })
            let items = try #require(handlers.items(for: original))
            let menu = NativeOwnMessageMenu.insert(items, into: NSMenu())
            let action = try #require(menu.items.first { $0.title == "Forward…" })
            let target = try #require(action.target as? ReactionMenuTrampoline)
            target.choose(action)
            #expect(chosen == original.id)
            original.isDeleted = true
            #expect(handlers.items(for: original)?.forward == nil)
            original.isDeleted = false
            original.id = .init("local/pending")
            #expect(handlers.items(for: original)?.forward == nil)
        }

        @Test func destinationPickerRendersAtNarrowAndRegularWidthsInBothAppearances() throws {
            let state = ChatSceneState(conversations: [
                Conversation(id: .init("team"), kind: .space, title: "Project team"),
                Conversation(id: .init("dm"), kind: .directMessage, title: "Taylor Example")
            ], directory: [.init("peer"): Member(
                id: .init("peer"),
                kind: .human,
                displayName: "Alex Example"
            )])
            for width in [CGFloat(380), CGFloat(540)] {
                for dark in [false, true] {
                    let preview = ForwardMessageSheet(
                        message: message(),
                        state: state,
                        send: { _, _, _ in true }
                    )
                    .frame(width: width).background(.background)
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
                    #expect(host.frame.width == width && host.frame.height > 300)
                    if let output = ProcessInfo.processInfo.environment["KIBBLE_FORWARD_RENDER_DIR"] {
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try #require(bitmap.representation(using: .png, properties: [:]))
                            .write(to: URL(fileURLWithPath: output)
                                .appendingPathComponent(
                                    "forward-\(Int(width))-\(dark ? "dark" : "light").png"
                                ))
                    }
                    withExtendedLifetime(window) {}
                }
            }
        }
    }
#endif
