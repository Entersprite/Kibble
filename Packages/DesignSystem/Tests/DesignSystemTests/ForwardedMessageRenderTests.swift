#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    struct ForwardedMessageRenderTests {
        @Test func forwardsRenderTheirSourceAndKeepTheOuterCommentSeparate() throws {
            for width in [CGFloat(320), CGFloat(600)] {
                for dark in [false, true] {
                    let preview = VStack(alignment: .leading, spacing: 16) {
                        row(body: "", comment: "My comment", deleted: false)
                        row(body: "The original message is included here.", comment: "", deleted: false)
                        row(
                            body: "Forwarded resources",
                            comment: "Please review",
                            deleted: false,
                            media: true
                        )
                        row(
                            body: "Removed source content",
                            comment: "A comment on the deleted original",
                            deleted: true
                        )
                    }
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
                    #expect(host.frame.height > 200)
                    try render(host, width: width, dark: dark)
                    withExtendedLifetime(window) {}
                }
            }
        }

        @Test func forwardOnlyHasNoEmptyCommentBubbleAndCannotLoseItsSourceThroughEditing() {
            let message = message(body: "", comment: "", deleted: false)
            #expect(!AttachmentLayout.parts(of: message, canLoadImages: false).showsText)
            #expect(!OwnMessageRule.canEdit(message, me: message.sender))
            #expect(OwnMessageRule.canDelete(message, me: message.sender))
        }

        /// A forward that carries only its addressed source, with no comment,
        /// draws that source as its card rather than an empty bubble.
        @Test func forwardWithOnlyItsSourceDrawsACardNotAnEmptyBubble() {
            var message = message(body: "Original body", comment: "", deleted: false)
            let source = message.content?.forwarded?.source
            message.content = MessageContent(forwardSource: source)
            #expect(message.content?.forwarded == nil)
            #expect(!AttachmentLayout.parts(of: message, canLoadImages: false).showsText)
            #expect(message.forwardedSnapshot?.source.text == "Original body")
            #expect(!OwnMessageRule.canEdit(message, me: message.sender))
        }

        private func row(body: String, comment: String, deleted: Bool, media: Bool = false) -> some View {
            var message = message(body: body, comment: comment, deleted: deleted)
            if media {
                message.content?.forwarded?.attachments = [Attachment(
                    id: "snapshot-file", name: "Project plan.pdf", contentType: "application/pdf"
                )]
                message.content?.forwarded?.links = [MessageLink(
                    url: URL(string: "https://example.test/plan")!,
                    preview: LinkPreview(title: "Project plan")
                )]
            }
            let scene = ChatSceneState(directory: [
                .init("forwarder"): Member(
                    id: .init("forwarder"),
                    kind: .human,
                    displayName: "Taylor Example"
                )
            ], messages: [message])
            return MessageBubble(message: message, state: MessageRowState(message: message, scene: scene))
        }

        private func message(body: String, comment: String, deleted: Bool) -> Message {
            let source = Message(
                id: .init("original"), conversationID: .init("source"), threadID: .init("source-thread"),
                sender: .init("author"), text: body, createdAt: Date(timeIntervalSince1970: 1),
                isDeleted: deleted
            )
            return Message(
                id: .init("received"), conversationID: .init("destination"), threadID: .init("thread"),
                sender: .init("forwarder"), text: comment, createdAt: Date(timeIntervalSince1970: 2),
                content: MessageContent(forwarded: ForwardedMessage(
                    source: MessageQuote(message: source),
                    senderName: "Alex Example With A Longer Display Name"
                ))
            )
        }

        private func render(_ host: NSView, width: CGFloat, dark: Bool) throws {
            guard let output = ProcessInfo.processInfo.environment["KIBBLE_MESSAGE_RENDER_DIR"]
            else { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: output)
                .appendingPathComponent("forwards-\(Int(width))-\(dark ? "dark" : "light").png"))
        }
    }
#endif
