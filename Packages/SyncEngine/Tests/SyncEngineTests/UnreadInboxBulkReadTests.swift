import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

extension UnreadInboxTests {
    @Test func aManualUnreadMarkReopensOnlyItsLocallyReadScope() throws {
        let main = message("main", offset: 1)
        let reply = message("reply", offset: 2, isReply: true)
        var otherReply = message("other-reply", offset: 2, isReply: true)
        otherReply.threadID = .init("another-thread")
        let store = try ChatStore.inMemory()
        try store.apply([
            .replaceConversations([Conversation(id: conversation, kind: .space, hasUnread: true)]),
            .applyThreadChange(thread: thread, conversation: conversation, change: .followed(true))
        ])
        try store.saveUnreadBulkReads([
            conversation: UnreadBulkRead(main: main.createdAt, replies: reply.createdAt)
        ])
        let cleared = try store.database.read(ChatStore.fetchUnreadBulkReads)
        #expect(cleared.covers(main) && cleared.covers(reply) && cleared.covers(otherReply))

        try store.apply([
            .setConversationUnreadMark(conversation: conversation, at: main.createdAt),
            .applyThreadChange(
                thread: thread,
                conversation: conversation,
                change: .markedUnread(at: reply.createdAt)
            )
        ])
        let reopened = try store.database.read(ChatStore.fetchUnreadBulkReads)
        #expect(!reopened.covers(main))
        #expect(!reopened.covers(reply))
        #expect(reopened.covers(otherReply))
    }

    @MainActor
    @Test func offlineMarkAllPersistsAcrossRestartAndLeavesTheNewHeadUnread() async throws {
        let old = message("before-mark", offset: 1)
        let arrived = message("after-mark", offset: 2)
        var room = Conversation(
            id: conversation, kind: .space, hasUnread: true,
            readPosition: boundary, latestMainMessageAt: old.createdAt
        )
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("inbox.sqlite").path
        let store = try ChatStore.onDisk(at: path)
        let backend = RecordingBackend(world: unreadWorld(rows: [old], room: room))
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: backend, store: store))
        try await model.start()
        model.showUnread()
        await settleAutoMarkRead(until: "the old row is visible") { model.visibleUnreadMessages == [old] }
        let offline = ConnectionState.reconnecting(attempt: 1, issue: nil, detail: nil)
        try store.apply([.setConnectionState(offline)])
        await settleAutoMarkRead(until: "the connection is offline") { model.connectionState == offline }

        model.markAllUnreadMessagesRead(in: [conversation])
        #expect(model.visibleUnreadMessages == [])
        #expect(model.locallyReadForBadge(room))
        await settleAutoMarkRead(until: "the pending receipt is on disk") {
            (try? store.unreadBulkReceiptState(in: conversation).0?.pendingMain) == old.createdAt
        }
        #expect(await backend.markReadCount == 0)
        await model.stop()

        room.latestMainMessageAt = arrived.createdAt
        let reopened = try ChatStore.onDisk(at: path)
        let nextBackend = RecordingBackend(world: unreadWorld(rows: [old, arrived], room: room))
        let next = ChatSessionModel(
            store: reopened,
            engine: SyncEngine(backend: nextBackend, store: reopened)
        )
        try await next.start()
        next.showUnread()
        await settleAutoMarkRead(until: "the old receipt is sent and the newer message stays unread") {
            await markReadPositions(from: nextBackend) == [old.createdAt] &&
                next.visibleUnreadMessages == [arrived] && !next.locallyReadForBadge(room)
        }
        await next.stop()
    }

    @MainActor
    @Test func markAllFetchesTheHeadForAnUnreadConversationWithNoKnownPosition() async throws {
        let head = message("head-without-metadata", offset: 4)
        let room = Conversation(
            id: conversation, kind: .directMessage, lastActivity: boundary, hasUnread: true
        )
        let backend = RecordingBackend(world: unreadWorld(rows: [head], room: room))
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: backend, store: store))
        try await model.start()
        model.showUnread()
        await settleAutoMarkRead(until: "the unread flag is visible without a history target") {
            model.unreadConversationIDs.contains(conversation) && model.unreadInbox?.messages == []
        }
        #expect(await backend.historyCursors.isEmpty)
        model.markAllUnreadMessagesRead(in: [conversation])
        await settleAutoMarkRead(until: "the confirmed main message is read") {
            await markReadPositions(from: backend) == [head.createdAt] &&
                !model.isMarkingAllUnread && !model.unreadConversationIDs.contains(conversation)
        }
        #expect(await backend.historyCursors == [nil])
        await model.stop()
    }

    @MainActor
    @Test func markAllReadsAnUnloadedThreadWhenItsOlderRootIsOutsideTheLatestPage() async throws {
        var root = message("older-topic", offset: -3)
        root.threadID = thread
        let reply = message("uncached-reply", offset: -2, isReply: true)
        let latest = message("newer-topic", offset: 1)
        let room = Conversation(
            id: conversation, kind: .space, readPosition: latest.createdAt,
            repliesEnabled: true, hasUnreadThread: true, latestMainMessageAt: latest.createdAt
        )
        var world = unreadWorld(rows: [root, reply, latest], room: room)
        world.threadStates[thread] = FixtureThreadState(isFollowed: true)
        let backend = RecordingBackend(
            world: world, capabilities: Capabilities(canMarkRead: true, supportsThreads: true), pageSize: 1
        )
        await backend.answerThread(thread, with: [root, reply], complete: true)
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: backend, store: store))
        try await model.start()
        model.showUnread()
        await settleAutoMarkRead(until: "the initial page misses the old topic") {
            model.unreadWork.checked[conversation] != nil && model.unreadInbox?.messages == []
        }
        try store.apply([.applyThreadChange(
            thread: thread, conversation: conversation, change: .counted(messages: 2, unread: 1)
        )])
        await settleAutoMarkRead(until: "the count adds a thread target without rows") {
            model.unreadConversationIDs.contains(conversation) && model.unreadInbox?.messages == []
        }
        model.markAllUnreadMessagesRead(in: [conversation])
        let command = ChatCommand.markThreadRead(
            conversationID: conversation,
            threadID: thread,
            upTo: reply.createdAt
        )
        await settleAutoMarkRead(until: "the old thread is read and no unread target remains") {
            await backend.commands.contains(command) && !model.isMarkingAllUnread
                && !model.unreadConversationIDs.contains(conversation)
        }
        #expect(await backend.threadLoads == [thread])
        #expect(await backend.markReadCount == 0)
        await model.stop()
    }

    @MainActor
    @Test func markAllWaitsForAnEarlierPartialReadAndThenCoversTheHead() async throws {
        let old = message("first", offset: 1)
        let latest = message("head", offset: 2)
        let room = Conversation(
            id: conversation, kind: .space, hasUnread: true,
            readPosition: boundary, latestMainMessageAt: latest.createdAt
        )
        let backend = RecordingBackend(world: unreadWorld(rows: [old, latest], room: room))
        await backend.holdSubmissions(true)
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: backend, store: store))
        try await model.start()
        model.showUnread()
        await settleAutoMarkRead(until: "both messages are in the inbox") {
            model.unreadInbox?.messages == [old, latest]
        }
        model.markUnreadMessagesRead([old], in: conversation)
        await settleAutoMarkRead(until: "the first receipt is held") { await backend.heldSubmissionCount == 1
        }
        model.markAllUnreadMessagesRead(in: [conversation])
        #expect(model.visibleUnreadMessages == [])
        #expect(await markReadPositions(from: backend) == [old.createdAt])

        await backend.holdSubmissions(false)
        await backend.releaseHeldSubmission()
        await settleAutoMarkRead(until: "the bulk receipt clears both messages") {
            await markReadPositions(from: backend) == [old.createdAt, latest.createdAt]
                && model.unreadInbox?.messages.isEmpty == true && !model.isMarkingAllUnread
        }
        await model.stop()
    }
}
