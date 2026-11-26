#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    struct MessageLinkQuoteRenderTests {
        @Test func resolvedAndUnavailableQuotesRenderInAHostedWindow() async throws {
            let source = Message(
                id: .init("original"),
                conversationID: .init("source"),
                threadID: .init("thread"),
                sender: .init("author"),
                text: "The original message appears here.",
                createdAt: Date(timeIntervalSince1970: 1)
            )
            let author = Member(id: source.sender, kind: .human, displayName: "Alex Example")
            let url = try #require(URL(string: "https://internal.example/original"))
            let address = try #require(MessageAddress(MessageQuote(message: source)))
            var loads = 0
            let root = VStack(alignment: .leading, spacing: 16) {
                MessageLinkQuote(link: MessageLink(url: url, messageAddress: address))
                MessageLinkQuote(link: MessageLink(url: url))
            }
            .padding(16).frame(width: 450, alignment: .leading).background(.background)
            .environment(\.loadMessageReference) { _ in
                loads += 1
                return (MessageQuote(message: source), author)
            }
            .environment(\.openMessageReference) { _ in }
            let host = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 450, height: 180),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            window.contentView = host
            window.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(x: 0, y: 0, width: 450, height: 180)
            host.layoutSubtreeIfNeeded()
            for _ in 0 ..< 100 where loads == 0 {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(loads == 1)
            host.layoutSubtreeIfNeeded()
            if let output = ProcessInfo.processInfo.environment["KIBBLE_MESSAGE_RENDER_DIR"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data
                    .write(to: URL(fileURLWithPath: output)
                        .appendingPathComponent("internal-link-quotes.png"))
            }
            withExtendedLifetime(window) {}
        }
    }
#endif
