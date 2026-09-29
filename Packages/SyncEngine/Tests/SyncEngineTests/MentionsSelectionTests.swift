import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// The Mentions row on the session model (the mentions-list spec §4).
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct MentionsSelectionTests {
    private let conversation = autoMarkReadConversation
    private let me = FixtureWorld.minimal.me

    private func mention(_ id: String, minutes: Double) -> Message {
        Message(
            id: Message.ID(id), conversationID: conversation,
            threadID: MessageThread.ID("fixture-seed-topic-1"), sender: Member.ID("fixture-other"),
            text: "@Me one more", createdAt: FixtureWorld.minimal.startedAt.addingTimeInterval(minutes * 60),
            mentions: [Mention(target: .user(me), start: 0, length: 3)]
        )
    }

    @Test func choosingMentionsLeavesNoConversationSelectedAndChoosingOneLeavesMentions() async throws {
        let harness = try await makeAutoMarkReadHarness()
        let model = harness.model
        model.select(conversation)
        await settleAutoMarkRead(until: "the conversation's messages load") { !model.messages.isEmpty }
        model.showMentions()
        #expect(model.showingMentions)
        #expect(model.selected == nil)
        #expect(model.messages.isEmpty)
        model.select(conversation)
        #expect(!model.showingMentions)
        #expect(model.selected == conversation)
        await model.stop()
    }

    /// The spec's guarantee: viewing the list reads nothing. The positive
    /// control comes first. With the conversation open, its newest message is
    /// marked, so a harness that could not mark at all cannot pass this.
    @Test func viewingTheMentionsListPublishesNoReadPosition() async throws {
        let harness = try await makeAutoMarkReadHarness()
        let model = harness.model
        model.select(conversation)
        await settleAutoMarkRead(until: "the open conversation is marked") {
            await harness.backend.markReadCount == 1
        }
        model.showMentions()
        try harness.store.apply([.upsertMessage(mention("m:while-listing", minutes: 30))])
        try await Task.sleep(for: .milliseconds(300))
        #expect(await harness.backend.markReadCount == 1)
        await model.stop()
    }

    /// Review Focus 5. A world load while the row is chosen (every reconnect)
    /// replaces the conversation list under it. The row stays chosen,
    /// nothing becomes selected, and nothing is marked.
    @Test func theMentionsRowSurvivesAConversationListReload() async throws {
        let harness = try await makeAutoMarkReadHarness()
        let model = harness.model
        model.showMentions()
        let reloaded = try harness.store.conversations().map { conversation in
            var copy = conversation
            copy.title = "reloaded"
            return copy
        }
        try harness.store.apply([.replaceConversations(reloaded)])
        await settleAutoMarkRead(until: "the reloaded list reaches the model") {
            !model.conversations.isEmpty && model.conversations.allSatisfy { $0.title == "reloaded" }
        }
        try harness.store.apply([.upsertMessage(mention("m:after-reload", minutes: 30))])
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.showingMentions)
        #expect(model.selected == nil)
        #expect(await harness.backend.markReadCount == 0)
        await model.stop()
    }

    @Test func openingAMentionSelectsItsConversationAndTargetsItsMessageUntilTheNextSelection() async throws {
        let harness = try await makeAutoMarkReadHarness()
        let model = harness.model
        model.showMentions()
        let target = FixtureWorld.minimal.messages[0].id
        model.open(conversation: conversation, message: target)
        #expect(model.selected == conversation)
        #expect(model.scrollTarget == target)
        #expect(!model.showingMentions)
        let elsewhere = try #require(model.conversations.first { $0.id != conversation }?.id)
        model.select(elsewhere)
        #expect(model.scrollTarget == nil)
        await model.stop()
    }

    @Test func theListItsBadgeAndTheSearchStatusFollowTheStore() async throws {
        let harness = try await makeAutoMarkReadHarness()
        let model = harness.model
        let found = mention("m:mention", minutes: 30)
        try harness.store.apply([
            .upsertMessage(found),
            .setMentionBackfill(MentionBackfillStatus(running: true))
        ])
        await settleAutoMarkRead(until: "the mention and the status reach the model") {
            model.mentions.map(\.message.id) == [found.id] && model.unreadMentionCount == 1
                && model.mentionBackfill.running
        }
        try harness.store.apply([
            .setReadState(conversation: conversation, lastReadAt: found.createdAt, unread: 0),
            .setMentionBackfill(MentionBackfillStatus(failedConversations: 2))
        ])
        await settleAutoMarkRead(until: "the read and the finished run reach the model") {
            model.unreadMentionCount == 0 && model.mentions.first?.isUnread == false
                && model.mentionBackfill == MentionBackfillStatus(failedConversations: 2)
        }
        await model.stop()
    }
}
