import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

/// A conversation is unread while the backend's newest main message
/// (`latestMainMessageAt`) is past its read position, and that message can
/// be one the transcript never shows. Every message shown is then at or
/// behind the read position, so the automatic mark was skipped as already
/// read and the dot stayed for good. Once the newest page has landed, the
/// mark covers the newest main message; before it lands, never.
@MainActor
@Suite(.timeLimit(.minutes(1)), .serialized)
struct AutoMarkReadNewestMainMessageTests {
    static let conversation = autoMarkReadConversation

    @Test func aFailedHeadVerificationWaitsForFocusBeforeRetrying() async throws {
        let harness = try await openedReadTranscript()
        await harness.backend.holdHistory(true)
        await harness.backend.failHistory(true)
        let (read, head) = try unreadForAHiddenHead(in: harness)
        await settleAutoMarkRead(until: "the head verification is held") {
            await harness.backend.abortableHistory.count == 1
        }
        let failed = try #require(harness.model.historyTask)
        let requests = await harness.backend.historyCursors.count
        for _ in 0 ..< 5 {
            harness.model.markSelectedReadIfNeeded()
        }
        #expect(await harness.backend.historyCursors.count == requests)
        await harness.backend.abortableHistory.release()
        await failed.value
        #expect(!harness.model.isLoadingLatestMessages)
        #expect(harness.model.transcriptWork.latestPageLoaded)
        #expect(harness.model.transcriptWork.verifiedLatestHead == read)
        #expect(await markReadPositions(from: harness.backend).isEmpty)
        // Nothing retries itself after the failure, even with no debounce.
        try await Task.sleep(for: .milliseconds(40))
        #expect(await harness.backend.historyCursors.count == requests)

        await harness.backend.failHistory(false)
        harness.model.setActive(false)
        harness.model.setActive(true)
        await settleAutoMarkRead(until: "focus retries the missing head verification") {
            let requested = await harness.backend.historyCursors.count
            return harness.model.isLoadingLatestMessages && requested > requests
        }
        await harness.backend.holdHistory(false)
        for _ in 0 ..< 4 {
            await harness.backend.abortableHistory.release()
            await Task.yield()
        }
        await settleAutoMarkRead(until: "the retried hidden head is marked") {
            await markReadPositions(from: harness.backend) == [head]
        }
        #expect(harness.model.transcriptWork.verifiedLatestHead == head)
        await harness.model.stop()
    }

    @Test func aCanceledHeadVerificationCanRetryAfterReconnect() async throws {
        let harness = try await openedReadTranscript()
        await harness.backend.holdHistory(true)
        let (read, head) = try unreadForAHiddenHead(in: harness)
        await settleAutoMarkRead(until: "the first head verification is held") {
            await harness.backend.abortableHistory.count == 1
        }
        harness.model.catchUpIfReconnected(.disconnected(reason: "test reconnect", issue: nil))
        harness.model.catchUpIfReconnected(.connected)
        await settleAutoMarkRead(until: "reconnect replaces the canceled verification") {
            let aborted = await harness.backend.abortableHistory.aborted
            let held = await harness.backend.abortableHistory.count
            return aborted == 1 && held == 1
        }
        let catchUp = try #require(harness.model.historyTask)
        await harness.backend.holdHistory(false)
        await harness.backend.abortableHistory.release()
        await catchUp.value
        #expect(harness.model.transcriptWork.latestPageLoaded)
        #expect(harness.model.transcriptWork.verifiedLatestHead == read)
        #expect(await markReadPositions(from: harness.backend).isEmpty)

        await harness.backend.holdHistory(true)
        harness.model.markSelectedReadIfNeeded()
        await settleAutoMarkRead(until: "an external read trigger retries the head verification") {
            await harness.backend.abortableHistory.count == 1
        }
        await harness.backend.holdHistory(false)
        await harness.backend.abortableHistory.release()
        await settleAutoMarkRead(until: "the head is marked after the retry") {
            await markReadPositions(from: harness.backend) == [head]
        }
        await harness.model.stop()
    }

    @Test func anInactiveChatDoesNotVerifyANewHiddenHead() async throws {
        let harness = try await openedReadTranscript()
        harness.model.setActive(false)
        let requests = await harness.backend.historyCursors.count
        let (_, head) = try unreadForAHiddenHead(in: harness)
        await settleAutoMarkRead(until: "the inactive chat observes the new head") {
            harness.model.conversations.first { $0.id == Self.conversation }?.latestMainMessageAt == head
        }
        try await Task.sleep(for: .milliseconds(40))
        #expect(await harness.backend.historyCursors.count == requests)
        #expect(await markReadPositions(from: harness.backend).isEmpty)
        await harness.model.stop()
    }

    private func openedReadTranscript() async throws -> TracedMarkReadHarness {
        let read = try autoMarkReadFixtureNewest
        var world = FixtureWorld.minimal
        let index = try #require(world.conversations.firstIndex { $0.id == Self.conversation })
        world.conversations[index].latestMainMessageAt = read.addingTimeInterval(60)
        let backend = RecordingBackend(world: world)
        let store = try ChatStore.inMemory()
        let sink = FakeMarkReadTraceSink()
        let model = ChatSessionModel(
            store: store, engine: SyncEngine(backend: backend, store: store), me: nil,
            markReadTrace: sink, markReadDebounce: .zero
        )
        try await model.start()
        await settleAutoMarkRead(until: "the fixture directory is observed") {
            model.conversations.count == world.conversations.count
        }
        let harness = TracedMarkReadHarness(model: model, backend: backend, store: store, sink: sink)
        try storeTheNewestPage(in: harness)
        var row = try #require(model.conversations.first { $0.id == Self.conversation })
        row.readPosition = read
        row.latestMainMessageAt = read
        try store.apply([.upsertConversation(row)])
        await settleAutoMarkRead(until: "the initial read head is observed") {
            model.conversations.first { $0.id == Self.conversation }?.latestMainMessageAt == read
        }
        model.select(Self.conversation)
        await settleAutoMarkRead(until: "the initial newest-page verification completes") {
            model.transcriptWork.latestPageLoaded && !model.isLoadingLatestMessages
        }
        return harness
    }

    @Test func aNewUnseenHeadWaitsForAFreshPageBeforeBeingMarked() async throws {
        let harness = try await makeTracedMarkReadHarness(markReadDebounce: .zero)
        try storeTheNewestPage(in: harness)
        let read = try autoMarkReadFixtureNewest
        var row = try #require(harness.model.conversations.first { $0.id == Self.conversation })
        row.readPosition = read
        try harness.store.apply([.upsertConversation(row)])
        await settleAutoMarkRead(until: "the read position is observed") {
            harness.model.conversations.first { $0.id == Self.conversation }?.readPosition == read
        }
        harness.model.select(Self.conversation)
        await settleAutoMarkRead(until: "the initial page lands") {
            harness.model.transcriptWork.latestPageLoaded
        }
        await harness.backend.holdHistory(true)
        let head = read.addingTimeInterval(60)
        row.latestMainMessageAt = head
        row.hasUnread = true
        try harness.store.apply([.upsertConversation(row)])
        for _ in 0 ..< 200 where await harness.backend.abortableHistory.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await markReadPositions(from: harness.backend).isEmpty)
        #expect(await !harness.backend.abortableHistory.isEmpty)
        await harness.backend.abortableHistory.release()
        await settleAutoMarkRead(until: "the verified hidden head is marked") {
            await markReadPositions(from: harness.backend) == [head]
        }
        await harness.model.stop()
    }

    /// The conversation read through every message its history returns,
    /// with the backend's newest main message a minute later.
    func unreadForAHiddenHead(in harness: TracedMarkReadHarness) throws -> (read: Date, head: Date) {
        let read = try autoMarkReadFixtureNewest
        let head = read.addingTimeInterval(60)
        var row = try #require(harness.model.conversations.first { $0.id == Self.conversation })
        row.readPosition = read
        row.latestMainMessageAt = head
        row.hasUnread = true
        try harness.store.apply([.upsertConversation(row)])
        return (read, head)
    }

    /// Every message the newest page brings, stored before the conversation
    /// opens, so the page landing changes no row and nothing is delivered.
    func storeTheNewestPage(in harness: TracedMarkReadHarness) throws {
        let page = FixtureWorld.minimal.messages.filter { $0.conversationID == Self.conversation }
        try harness.store.apply(page.map { .upsertMessage($0) })
    }

    @Test func aHiddenHeadIsMarkedOnceTheNewestPageLands() async throws {
        let harness = try await makeTracedMarkReadHarness(markReadDebounce: .zero)
        try storeTheNewestPage(in: harness)
        let (read, head) = try unreadForAHiddenHead(in: harness)
        await settleAutoMarkRead(until: "the head is observed") {
            harness.model.conversations.first { $0.id == Self.conversation }?.latestMainMessageAt == head
        }
        await harness.backend.holdHistory(true)
        harness.model.select(Self.conversation)
        // Before the page lands, the transcript's newest is all there is to
        // mark, and it is already read.
        await settleAutoMarkRead(until: "the shown messages are skipped") {
            markReadTriggerCount(.alreadyReadOnServer, in: harness) >= 1
        }
        #expect(await markReadPositions(from: harness.backend).isEmpty)
        #expect(harness.model.published[Self.conversation] == read)

        await settleAutoMarkRead(until: "the newest page is held on the backend") {
            await harness.backend.abortableHistory.count == 1
        }
        await harness.backend.abortableHistory.release()
        await settleAutoMarkRead(until: "the head is marked") {
            await markReadPositions(from: harness.backend) == [head]
        }
        #expect(harness.model.published[Self.conversation] == head)
        await harness.model.stop()
    }

    /// The open conversation's page has landed and everything shown is read;
    /// then a directory load moves the head past it. No transcript row
    /// changes, so only the conversation's own update can mark it.
    @Test func aHeadThatMovesPastTheOpenTranscriptIsMarked() async throws {
        let harness = try await makeTracedMarkReadHarness(markReadDebounce: .zero)
        try storeTheNewestPage(in: harness)
        let read = try autoMarkReadFixtureNewest
        var row = try #require(harness.model.conversations.first { $0.id == Self.conversation })
        row.readPosition = read
        try harness.store.apply([.upsertConversation(row)])
        await settleAutoMarkRead(until: "the read position is observed") {
            harness.model.conversations.first { $0.id == Self.conversation }?.readPosition == read
        }
        harness.model.select(Self.conversation)
        await settleAutoMarkRead(until: "the newest page lands") {
            harness.model.transcriptWork.latestPageLoaded && !harness.model.isLoadingLatestMessages
        }
        await settleAutoMarkRead()
        // Positive control: read, so nothing is sent before the head moves.
        try #require(await markReadPositions(from: harness.backend).isEmpty)

        let head = read.addingTimeInterval(60)
        row.latestMainMessageAt = head
        row.hasUnread = true
        try harness.store.apply([.upsertConversation(row)])
        await settleAutoMarkRead(until: "the moved head is marked") {
            await markReadPositions(from: harness.backend) == [head]
        }
        await harness.model.stop()
    }
}
