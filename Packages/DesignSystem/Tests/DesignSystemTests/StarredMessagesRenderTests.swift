#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    @Suite(.enabled(if: visibleUITestsEnabled), .serialized)
    struct StarredMessagesRenderTests {
        @Test(arguments: [false, true], [false, true])
        func theStarredPaneFitsTheDetailColumn(_ dark: Bool, emptyPage: Bool) async throws {
            let conversation = Conversation(id: .init("design"), kind: .space, title: "Design Team")
            let sender = Member(id: .init("person"), kind: .human, displayName: "Casey")
            let message = Message(
                id: .init("star"), conversationID: conversation.id, threadID: .init("thread"),
                sender: sender.id, text: "Share the final design notes after the review.",
                createdAt: Date(timeIntervalSince1970: 1_798_416_000)
            )
            var state = ChatSceneState(conversations: [conversation], directory: [sender.id: sender])
            state.stars.showingList = true
            state.stars.messages = emptyPage ? [] : [message]
            state.stars.hasMore = true
            let actions = StarredMessagesActions(show: {}, refresh: {}, loadMore: {}, set: { _, _ in })
            let pane = StarredMessagesPane(state: state, actions: actions, open: { _ in })
                .environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: 420, height: 320)
            let host = NSHostingView(rootView: pane)
            let bounds = NSRect(x: 0, y: 0, width: 420, height: 320)
            let window = NSWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            for _ in 0 ..< 10 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(host.frame.size == CGSize(width: 420, height: 320))
            if let output = ProcessInfo.processInfo.environment["KIBBLE_STARRED_RENDER_DIR"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent(
                        "starred-\(emptyPage ? "empty-" : "")\(dark ? "dark" : "light").png"
                    ))
            }
        }
    }
#endif
