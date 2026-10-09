import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// The Threads row, its pane and the ways into a thread from elsewhere
/// (threads spec §4.3, §5.3).
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ThreadListTests {
    private let conversation = ThreadFixture.conversation
    private let thread = ThreadFixture.thread

    /// The world load's own fetch, waited for so a count after it is this test's.
    private func harness() async throws -> AutoMarkReadHarness {
        let harness = try await makeThreadHarness()
        await settleAutoMarkRead(until: "the world load has fetched the list") {
            await harness.backend.followedThreadLoads == 1
        }
        return harness
    }

    @Test func showingTheListLeavesNoConversationOrPanelAndFetchesTheList() async throws {
        let harness = try await harness()
        let model = harness.model
        try openStoredThread(ThreadFixture.messages(replies: 1), in: harness)
        #expect(model.threads.openThread == thread)
        model.showThreads()
        #expect(model.threads.showingList)
        #expect(model.selected == nil)
        #expect(model.messages.isEmpty)
        #expect(model.threads.openThread == nil)
        await settleAutoMarkRead(until: "opening the list fetches it") {
            await harness.backend.followedThreadLoads == 2
        }
        model.showThreads()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await harness.backend.followedThreadLoads == 2)
        model.showMentions()
        #expect(!model.threads.showingList)
        #expect(model.showingMentions)
        model.showThreads()
        #expect(!model.showingMentions)
        model.select(conversation)
        #expect(!model.threads.showingList)
        await model.stop()
    }

    @Test func theListAndItsBadgeFollowTheStore() async throws {
        let harness = try await harness()
        let model = harness.model
        let messages = ThreadFixture.messages(replies: 2)
        try harness.store.apply(messages.map { .upsertMessage($0) } + [
            .applyThreadChange(thread: thread, conversation: conversation, change: .followed(true)),
            .applyThreadChange(
                thread: thread, conversation: conversation, change: .counted(messages: 3, unread: 1)
            )
        ])
        await settleAutoMarkRead(until: "the followed, unread thread reaches the list and the badge") {
            model.threads.followed.map(\.thread.id) == [thread] && model.threads.unreadCount == 1
        }
        #expect(model.threads.followed.first?.root.id == messages[0].id)
        try harness.store.apply([
            .applyThreadChange(
                thread: thread, conversation: conversation, change: .counted(messages: 3, unread: 0)
            )
        ])
        await settleAutoMarkRead(until: "the read thread leaves the badge") { model.threads.unreadCount == 0 }
        await model.stop()
    }

    @Test func aRefusedListIsRecorded() async throws {
        let harness = try await harness()
        await harness.backend.failThreadCalls(true)
        harness.model.showThreads()
        await settleAutoMarkRead(until: "the refusal is recorded") { harness.model.lastError != nil }
        await harness.model.stop()
    }

    /// Spec §5.3: selects the conversation, scrolls to the first message, opens the panel.
    @Test func openingAListItemSelectsItsConversationAndOpensThePanel() async throws {
        let harness = try await harness()
        let model = harness.model
        let messages = ThreadFixture.messages(replies: 1)
        try harness.store.apply(messages.map { .upsertMessage($0) })
        model.showThreads()
        model.openThreadItem(thread, in: conversation)
        #expect(model.selected == conversation)
        #expect(!model.threads.showingList)
        #expect(model.threads.openThread == thread)
        #expect(model.scrollTarget == messages[0].id)
        #expect(model.threads.scrollTarget == nil)
        await model.stop()
    }

    /// A reply is not in the transcript, so a mention of one (or its
    /// notification) opens the panel at it; any other message keeps today's way.
    @Test func openingAMentionOfAReplyOpensThePanelAtItAndAnyOtherTheTranscript() async throws {
        let harness = try await harness()
        let model = harness.model
        let messages = ThreadFixture.messages(replies: 1)
        try harness.store.apply(messages.map { .upsertMessage($0) })
        model.showMentions()
        model.open(conversation: conversation, message: messages[1].id)
        #expect(model.selected == conversation)
        #expect(model.threads.openThread == thread)
        #expect(model.threads.scrollTarget == messages[1].id)
        #expect(model.scrollTarget == messages[0].id)

        model.closeThread()
        model.open(conversation: conversation, message: messages[0].id)
        #expect(model.threads.openThread == nil)
        #expect(model.scrollTarget == messages[0].id)
        await model.stop()
    }
}
