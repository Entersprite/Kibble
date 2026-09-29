import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// Opening a mention scrolls the transcript to it once. After that, arrivals
/// scroll to the newest as before (ruling 14).
struct TranscriptScrollTests {
    private func message(_ id: String) -> Message {
        Message(
            id: Message.ID(id), conversationID: Conversation.ID("space:1"), threadID: MessageThread.ID("t"),
            sender: Member.ID("users/alice"), text: id, createdAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
    }

    private var messages: [Message] {
        [message("m:1"), message("m:2"), message("m:3")]
    }

    @Test func aLoadedTargetNotYetHonouredIsScrolledTo() {
        #expect(TranscriptScroll.destination(messages: messages, target: Message.ID("m:1"), honoured: nil)
            == .message(Message.ID("m:1")))
    }

    @Test func anHonouredTargetGivesWayToTheNewest() {
        #expect(TranscriptScroll.destination(
            messages: messages, target: Message.ID("m:1"), honoured: Message.ID("m:1")
        ) == .newest(Message.ID("m:3")))
    }

    @Test func aTargetNotLoadedYetShowsTheNewestUntilItArrives() {
        #expect(TranscriptScroll.destination(messages: messages, target: Message.ID("m:9"), honoured: nil)
            == .newest(Message.ID("m:3")))
    }

    @Test func noTargetIsTheNewestAndNoMessagesIsNothing() {
        #expect(TranscriptScroll.destination(messages: messages, target: nil, honoured: nil)
            == .newest(Message.ID("m:3")))
        #expect(TranscriptScroll.destination(messages: [], target: Message.ID("m:1"), honoured: nil) == nil)
    }

    /// The trigger must change when a target is set on messages already
    /// loaded, or the scroll would wait for the next arrival.
    @Test func theTriggerChangesWhenATargetIsSetOnLoadedMessages() {
        var state = ChatSceneState(messages: messages)
        let before = TranscriptScroll.Trigger(state)
        state.scrollTarget = Message.ID("m:1")
        #expect(TranscriptScroll.Trigger(state) != before)
        // Moving the target between two loaded messages leaves `newest` and
        // `targetLoaded` as they were, so only `target` can fire this.
        let onFirst = TranscriptScroll.Trigger(state)
        state.scrollTarget = Message.ID("m:2")
        #expect(TranscriptScroll.Trigger(state) != onFirst)
    }

    /// A target that loads without becoming the newest (an older page
    /// arriving) leaves `newest` and `target` as they were, so only
    /// `targetLoaded` can fire the scroll.
    @Test func theTriggerChangesWhenAnOlderTargetLoads() {
        var state = ChatSceneState(
            messages: [message("m:2"), message("m:3")], scrollTarget: Message.ID("m:1")
        )
        let before = TranscriptScroll.Trigger(state)
        state.messages.insert(message("m:1"), at: 0)
        #expect(TranscriptScroll.Trigger(state) != before)
    }
}
