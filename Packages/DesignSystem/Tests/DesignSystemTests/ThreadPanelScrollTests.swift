import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// Where the panel scrolls: a reply it was opened at, once, else the newest.
struct ThreadPanelScrollTests {
    private func message(_ id: String) -> Message {
        Message(
            id: Message.ID(id), conversationID: Conversation.ID("space/s-1"),
            threadID: MessageThread.ID("t-1"), sender: Member.ID("u-2"), text: id,
            createdAt: Date(timeIntervalSince1970: 0), isReply: id != "first"
        )
    }

    private func panel(target: String?) -> ThreadPanelState {
        ThreadPanelState(
            thread: MessageThread(id: MessageThread.ID("t-1"), conversationID: Conversation.ID("space/s-1")),
            conversationTitle: "Deploys",
            messages: [message("first"), message("r-1"), message("r-2")],
            scrollTarget: target.map { Message.ID($0) }
        )
    }

    @Test func withoutATargetTheNewestReply() {
        let destination = ThreadPanelScroll.destination(panel: panel(target: nil), honored: nil)
        #expect(destination == .newest(Message.ID("r-2")))
    }

    @Test func aTargetOnceThenTheNewest() {
        let opened = panel(target: "r-1")
        #expect(ThreadPanelScroll.destination(panel: opened, honored: nil) == .message(Message.ID("r-1")))
        let afterwards = ThreadPanelScroll.destination(panel: opened, honored: Message.ID("r-1"))
        #expect(afterwards == .newest(Message.ID("r-2")))
    }
}
