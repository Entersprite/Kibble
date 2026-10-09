import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// The thread panel on the session model (threads spec §4.3): opening,
/// closing, replies, following and catch-up.
///
/// **In the background** (`setActive(false)`), so the panel's own
/// auto-mark-read sends nothing these tests count; `ThreadAutoMarkReadTests`
/// is about that.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ThreadPanelTests {
    private let thread = ThreadFixture.thread

    /// The panel open on the fixture thread, its messages delivered and its
    /// one fetch made, so a later hold or failure meets only what the test
    /// does next.
    private func opened(
        replies: Int = 2, capabilities: Capabilities = ThreadFixture.capabilities
    ) async throws -> AutoMarkReadHarness {
        let harness = try await makeThreadHarness(capabilities: capabilities)
        harness.model.setActive(false)
        try openStoredThread(ThreadFixture.messages(replies: replies), in: harness)
        await settleAutoMarkRead(until: "the thread reaches the panel and is fetched") {
            let loads = await harness.backend.threadLoads.count
            return harness.model.threads.messages.count == replies + 1 && loads == 1
        }
        return harness
    }

    /// An outage and its end through the store the model watches, waiting for
    /// the model to see the outage so the two writes are two transitions.
    private func reconnect(_ harness: AutoMarkReadHarness) async throws {
        try harness.store.apply([.setConnectionState(.reconnecting(attempt: 1, issue: nil, detail: nil))])
        await settleAutoMarkRead(until: "the model sees the outage") {
            harness.model.connectionState != .connected
        }
        try harness.store.apply([.setConnectionState(.connected)])
    }

    @Test func openingAThreadShowsItsMessagesOldestFirstAndFetchesIt() async throws {
        let harness = try await opened()
        #expect(harness.model.threads.openThread == thread)
        #expect(harness.model.threads.messages.map(\.id) == ThreadFixture.messages(replies: 2).map(\.id))
        #expect(await harness.backend.threadLoads == [thread])
        await harness.model.stop()
    }

    @Test func closingEmptiesThePanelAndStopsWatchingTheThread() async throws {
        let harness = try await opened()
        harness.model.closeThread()
        #expect(harness.model.threads.openThread == nil)
        #expect(harness.model.threads.messages.isEmpty)
        try harness.store.apply([.upsertMessage(ThreadFixture.messages(replies: 3)[3])])
        try await Task.sleep(for: .milliseconds(150))
        #expect(harness.model.threads.messages.isEmpty)
        await harness.model.stop()
    }

    /// Spec §4.3: switching conversation closes the panel. The summaries the
    /// marks read are the newly selected conversation's.
    @Test func selectingAnotherConversationClosesThePanelAndSwapsTheSummaries() async throws {
        let harness = try await opened()
        let model = harness.model
        await settleAutoMarkRead(until: "the thread's summary reaches the marks") {
            model.threads.summaries[thread]?.replyCount == 3
        }
        let other = try #require(model.conversations.first { $0.id != ThreadFixture.conversation }?.id)
        model.select(other)
        #expect(model.threads.openThread == nil)
        #expect(model.threads.messages.isEmpty)
        #expect(model.threads.summaries[thread] == nil)
        try harness.store.apply([.upsertMessage(ThreadFixture.messages(replies: 3)[3])])
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.threads.messages.isEmpty)
        #expect(model.threads.summaries[thread] == nil)
        await model.stop()
    }

    @Test func aReplyIsShownAtOnceAndNeverInTheTranscript() async throws {
        let harness = try await opened()
        let model = harness.model
        await settleAutoMarkRead(until: "you are known") { model.me != nil }
        model.sendReply(ComposedMessage(text: "on it"))
        await settleAutoMarkRead(until: "the reply reaches the panel") {
            model.threads.messages.contains { $0.text == "on it" }
        }
        let reply = try #require(model.threads.messages.first { $0.text == "on it" })
        #expect(reply.isReply)
        #expect(reply.threadID == thread)
        #expect(reply.id.rawValue.hasPrefix("local/"))
        // The positive control: a top-level message sent after the reply
        // reaches the transcript, so the transcript has seen the reply's write.
        model.send(ComposedMessage(text: "top level"))
        await settleAutoMarkRead(until: "the top-level message reaches the transcript") {
            model.messages.contains { $0.text == "top level" }
        }
        #expect(!model.messages.contains { $0.text == "on it" })
        let sends = await harness.backend.commands.filter { command in
            if case .sendMessage = command {
                true
            } else {
                false
            }
        }
        #expect(sends.first == .sendMessage(
            conversationID: ThreadFixture.conversation, threadID: thread, text: "on it",
            localID: reply.localID
        ))
        await model.stop()
    }

    /// The refusal and the retraction land in one transaction
    /// (`SyncEngine.record(_:undoing:)`), so once the error shows the row is gone.
    @Test func aRefusedReplyIsTakenBackAndRecorded() async throws {
        let harness = try await opened()
        let model = harness.model
        await settleAutoMarkRead(until: "you are known") { model.me != nil }
        await harness.backend.failSubmissions(true)
        model.sendReply(ComposedMessage(text: "never sent"))
        await settleAutoMarkRead(until: "the refusal is recorded") { model.lastError != nil }
        let localID = try #require(await harness.backend.commands.compactMap { command -> String? in
            if case let .sendMessage(_, _, _, localID, _, _) = command {
                localID
            } else {
                nil
            }
        }.first)
        #expect(try harness.store.message(Message.ID("local/\(localID)")) == nil)
        await model.stop()
    }

    @Test func followingWaitsForTheAnswerAndOneRunsAtATime() async throws {
        let harness = try await opened()
        let model = harness.model
        await harness.backend.holdThreadCalls(true)
        model.setFollowed(true)
        #expect(model.threads.followPending)
        await settleAutoMarkRead(until: "the follow is asked") {
            await harness.backend.heldThreadCallCount == 1
        }
        model.setFollowed(false)
        await harness.backend.releaseHeldThreadCall()
        await settleAutoMarkRead(until: "the follow is answered") { !model.threads.followPending }
        await settleAutoMarkRead(until: "the thread shows followed") {
            model.threads.summaries[thread]?.isFollowed == true
        }
        #expect(await harness.backend.followRequests == [true])
        await model.stop()
    }

    @Test func aRefusedFollowIsRecordedAndReleasesTheToggle() async throws {
        let harness = try await opened()
        let model = harness.model
        await harness.backend.failThreadCalls(true)
        model.setFollowed(true)
        await settleAutoMarkRead(until: "the refusal is recorded and the toggle released") {
            model.lastError != nil && !model.threads.followPending
        }
        #expect(model.threads.summaries[thread]?.isFollowed != true)
        await model.stop()
    }

    /// Spec §4.3: after a reconnect, an open thread is reloaded with `loadThread`.
    @Test func reconnectingFetchesTheOpenThreadAgainAndAClosedOneNot() async throws {
        let harness = try await opened()
        let model = harness.model
        try await reconnect(harness)
        await settleAutoMarkRead(until: "the open thread is fetched again") {
            await harness.backend.threadLoads.count == 2
        }
        model.closeThread()
        let conversationLoads = await harness.backend.loadMessagesCount
        try await reconnect(harness)
        await settleAutoMarkRead(until: "the conversation is fetched again") {
            await harness.backend.loadMessagesCount == conversationLoads + 1
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await harness.backend.threadLoads.count == 2)
        await model.stop()
    }

    @Test func aBackendThatCannotSendIsNotAskedToReply() async throws {
        var capabilities = ThreadFixture.capabilities
        capabilities.canSendMessages = false
        let harness = try await opened(capabilities: capabilities)
        harness.model.sendReply(ComposedMessage(text: "not sent"))
        try await Task.sleep(for: .milliseconds(150))
        #expect(harness.model.threads.messages.count == 3)
        #expect(await harness.backend.commands.isEmpty)
        await harness.model.stop()
    }

    /// `stop()`'s own reason, for every thread call the model starts: the
    /// list's fetch, the panel's and a Follow, each held across `stop()`,
    /// answer into a store that must not take them (`ThreadWork.cancelAll()`).
    @Test func stopKeepsHeldThreadCallsOutOfTheStore() async throws {
        let harness = try await makeThreadHarness()
        let model = harness.model
        let backend = harness.backend
        await settleAutoMarkRead(until: "the world load has fetched the list") {
            await backend.followedThreadLoads == 1
        }
        let page = ThreadFixture.messages(replies: 2)
        let list = ThreadFixture.messages(in: ThreadFixture.otherThread, replies: 1, offset: 600)
        await backend.answerThread(thread, with: page)
        await backend.answerFollowedThreads(with: list)
        await backend.holdThreadCalls(true)
        model.showThreads()
        try openStoredThread([page[0]], in: harness)
        model.setFollowed(true)
        await settleAutoMarkRead(until: "the list, the page and the follow are asked") {
            await backend.heldThreadCallCount == 3
        }
        await model.stop()
        for _ in 0 ..< 3 {
            await backend.releaseHeldThreadCall()
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(try harness.store.message(list[1].id) == nil)
        #expect(try harness.store.message(page[1].id) == nil)
        #expect(try harness.store.thread(thread, in: ThreadFixture.conversation)?.isFollowed != true)
        #expect(try harness.store.lastError() == nil)
    }

    @Test func withoutThreadsNoPanelOpensAndNoListShows() async throws {
        var capabilities = ThreadFixture.capabilities
        capabilities.supportsThreads = false
        let harness = try await makeThreadHarness(capabilities: capabilities)
        let model = harness.model
        try openStoredThread(ThreadFixture.messages(replies: 1), in: harness)
        #expect(model.threads.openThread == nil)
        model.showThreads()
        #expect(!model.threads.showingList)
        #expect(model.selected == ThreadFixture.conversation)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await harness.backend.threadLoads.isEmpty)
        #expect(await harness.backend.followedThreadLoads == 0)
        await model.stop()
    }
}
