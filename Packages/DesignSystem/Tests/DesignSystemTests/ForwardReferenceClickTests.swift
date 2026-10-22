#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    struct ForwardReferenceClickTests {
        @Test func hostedForwardTextOpensItsSourceWhileSelectionAndNestedLinksKeepTheirOwnActions() throws {
            let message = Message(
                id: .init("original"),
                conversationID: .init("source"),
                threadID: .init("thread"),
                sender: .init("author"),
                text: "Original https://example.test/",
                createdAt: Date(timeIntervalSince1970: 1)
            )
            var opened: [MessageAddress] = []
            let host = NSHostingView(rootView: ForwardedMessageCard(
                forwarded: ForwardedMessage(source: MessageQuote(message: message)), directory: [:]
            ).environment(\.openMessageReference) { opened.append($0) })
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
            host.layoutSubtreeIfNeeded()
            let text = try #require(findText(in: host))
            text.setSelectedRange(NSRange(location: 0, length: 0))
            text.openReferenceAfterClick(at: 0, count: 1)
            #expect(opened == [MessageAddress(MessageQuote(message: message))].compactMap(\.self))
            text.openReferenceAfterClick(at: 0, count: 2)
            text.setSelectedRange(NSRange(location: 0, length: 4))
            text.openReferenceAfterClick(at: 0, count: 1)
            text.setSelectedRange(NSRange(location: 0, length: 0))
            text.openReferenceAfterClick(at: 12, count: 1)
            #expect(opened.count == 1)
        }

        private func findText(in view: NSView) -> BubbleTextView? {
            if let view = view as? BubbleTextView {
                return view
            }
            return view.subviews.lazy.compactMap { findText(in: $0) }.first
        }
    }
#endif
