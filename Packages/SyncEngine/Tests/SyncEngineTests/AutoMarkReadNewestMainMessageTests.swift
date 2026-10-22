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
