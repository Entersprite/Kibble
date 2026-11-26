#if os(macOS)
    import AppKit
    import ChatKit
    import SwiftUI
    import Testing
    @testable import DesignSystem

    @MainActor
    struct MessageActivityRenderTests {
        @Test func emptyPinActivityRendersAsACompactIndependentRow() {
            let message = Message(
                id: .init("activity"), conversationID: .init("room"), threadID: .init("thread"),
                sender: .init("peer"), text: "", createdAt: .distantPast, activity: .pinnedMessage
            )
            let scene = ChatSceneState(directory: [
                .init("peer"): Member(id: .init("peer"), kind: .human, displayName: "Alex")
            ], messages: [message])
            for width in [CGFloat(280), CGFloat(600)] {
                for dark in [false, true] {
                    let view = MessageBubble(message: message, state: .init(message: message, scene: scene))
                        .frame(width: width).environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    #expect(host.fittingSize.width == width)
                    #expect(host.fittingSize.height >= 25 && host.fittingSize.height < 60)
                }
            }
            #expect(MessageActivityRow(activity: .pinnedMessage, sender: "Alex")
                .title == "Alex pinned a message")
            var previous = message; previous.activity = nil
            #expect(!TranscriptGrouping.continues(message, after: previous))
            #expect(!OwnMessageRule.canEdit(message, me: message.sender))
        }
    }
#endif
