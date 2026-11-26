import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
struct UnreadInboxTests {
    let conversation = Conversation.ID("inbox-room")
    let thread = MessageThread.ID("inbox-thread")
    private let me = Member.ID("me")
    private let peer = Member.ID("peer")
    let boundary = Date(timeIntervalSince1970: 1_600_000_000)

    func message(
        _ id: String, offset: Double, sender: Member.ID? = nil,
        isReply: Bool = false, isDeleted: Bool = false
    ) -> Message {
        Message(
            id: Message.ID(id), conversationID: conversation,
            threadID: isReply ? thread : MessageThread.ID(id),
            sender: sender ?? peer, text: id, createdAt: boundary.addingTimeInterval(offset),
            isDeleted: isDeleted, isReply: isReply
        )
    }

    @Test func inboxUsesIndependentReadPositionsAndConfirmedIncomingRows() throws {
        let store = try ChatStore.inMemory()
        let room = Conversation(
            id: conversation,
            kind: .space,
            hasUnread: true,
            isMuted: true,
            readPosition: boundary
        )
        let rows = [
            message("main-read", offset: 0),
            message("main-unread", offset: 0.000_001),
            message("own", offset: 1, sender: me),
            message("local/pending", offset: 1),
            message("deleted", offset: 1, isDeleted: true),
            message("reply-read", offset: -2, isReply: true),
            message("reply-before-mark", offset: -1.5, isReply: true),
            message("reply-unread", offset: -1, isReply: true)
        ]
        try store.apply([
            .setLocalMember(me), .replaceConversations([room]),
            .applyThreadChange(
                thread: thread, conversation: conversation,
                change: .read(upTo: boundary.addingTimeInterval(-2))
            ),
            .applyThreadChange(thread: thread, conversation: conversation, change: .followed(true))
        ] + rows.map { .upsertMessage($0) })
        #expect(try ids(in: store) == ["reply-before-mark", "reply-unread", "main-unread"])

        try store.apply([
            .setReadState(conversation: conversation, lastReadAt: rows[1].createdAt, unread: 0),
            .applyThreadChange(
                thread: thread,
                conversation: conversation,
                change: .markedUnread(at: boundary.addingTimeInterval(-1))
            )
        ])
        #expect(try ids(in: store) == ["reply-unread"])

        try store.apply([.invalidateReplicaHistory])
        #expect(try ids(in: store).isEmpty)
    }

    @MainActor
    @Test func openingBackfillsSeveralPagesAndMarkReadStopsAtTheDisplayedMessage() async throws {
        var rows = (0 ... 6).map { message("message-\($0)", offset: Double($0)) }
        rows[0].threadID = thread
        let reply = message("thread-reply", offset: 0.5, isReply: true)
        rows.insert(reply, at: 1)
        var world = unreadWorld(
            rows: rows,
            room: Conversation(
                id: conversation, kind: .space, lastActivity: rows.last?.createdAt,
                hasUnread: true, readPosition: boundary, repliesEnabled: true,
                hasUnreadThread: true, latestMainMessageAt: rows.last?.createdAt
            )
        )
        world.threadStates[thread] = FixtureThreadState(isFollowed: true, readPosition: boundary)
        let backend = FakeBackend(world: world, pageSize: 2)
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(store: store, engine: engine, markReadDebounce: .seconds(3600))
        try await model.start()
        model.setActive(true)
        model.showUnread()
        await settleAutoMarkRead(until: "the full unread history is observed") {
            model.unreadInbox?.messages == Array(rows.dropFirst()) && !model.unreadHistoryLoading
        }
        #expect(model.selected == nil)
        let displayed = try #require(model.unreadInbox?.messages)

        let newest = try #require(displayed.last)
        model.markInboxMessageRead(newest)
        await settleAutoMarkRead(until: "only the individually marked message is removed") {
            model.unreadInbox?.messages == Array(displayed.dropLast())
                && model.unreadInbox?.readOnThisDevice == [newest]
        }
        #expect(try store.conversation(conversation)?.readPosition == boundary)
        let snapshot = try #require(model.unreadInbox)

        let arrived = message("just-arrived", offset: 7)
        try store.apply([.upsertMessage(arrived), .upsertConversation(Conversation(
            id: conversation, kind: .space, lastActivity: arrived.createdAt, hasUnread: true,
            readPosition: boundary, latestMainMessageAt: arrived.createdAt
        ))])
        await settleAutoMarkRead(until: "newer head is observed") {
            model.unreadInbox?.messages.last == arrived
                && model.conversations.first?.latestMainMessageAt == arrived.createdAt
        }
        model.markUnreadMessagesRead(snapshot.messages + snapshot.readOnThisDevice, in: conversation)
        await settleAutoMarkRead(until: "the captured rows clear and the newer message remains") {
            model.unreadInbox?.messages == [arrived] && model.unreadInbox?.readOnThisDevice == []
        }
        #expect(try store.conversation(conversation)?.readPosition == displayed.last?.createdAt)
        #expect(try store.thread(thread, in: conversation)?.readPosition == reply.createdAt)
        await model.stop()
    }

    @Test func aCountWithoutAReadPositionLimitsEachScopeIndependently() throws {
        let store = try ChatStore.inMemory()
        var rows = [
            message("main-old", offset: -3),
            message("reply-old", offset: -2, isReply: true),
            message("main-new", offset: -1),
            message("reply-new", offset: 0, isReply: true)
        ]
        rows[0].threadID = thread
        let room = Conversation(
            id: conversation, kind: .space, unreadCount: 1, latestMainMessageAt: rows[2].createdAt
        )
        try store.apply([
            .setLocalMember(me), .replaceConversations([room]),
            .applyThreadChange(
                thread: thread, conversation: conversation, change: .counted(messages: 3, unread: 1)
            )
        ] + rows.prefix(2).map { .upsertMessage($0) })
        #expect(try ids(in: store).isEmpty)
        try store.apply(rows.suffix(2).map { .upsertMessage($0) })
        #expect(try ids(in: store) == ["main-new", "reply-new"])
        try store.markInboxMessageRead(MessageAddress(rows[2]))
        #expect(try ids(in: store) == ["reply-new"])
        try store.markInboxMessageRead(MessageAddress(rows[3]))
        #expect(try ids(in: store).isEmpty)
        try store.apply([.applyThreadChange(
            thread: thread, conversation: conversation, change: .markedUnread(at: rows[1].createdAt)
        )])
        #expect(try ids(in: store) == ["reply-old", "reply-new"])

        try store.apply([.replaceConversations([])])
        #expect(try ids(in: store).isEmpty)
    }

    @Test func readConversationsAndCountedThreadsDoNotResurfaceCachedHistory() throws {
        let store = try ChatStore.inMemory()
        let room = Conversation(id: conversation, kind: .space, readPosition: boundary)
        let rows = [
            message("cached-main", offset: 1),
            message("earlier-reply", offset: 2, isReply: true),
            message("newest-reply", offset: 3, isReply: true)
        ]
        try store.apply([
            .setLocalMember(me), .replaceConversations([room]),
            .applyThreadChange(thread: thread, conversation: conversation, change: .read(upTo: boundary)),
            .applyThreadChange(
                thread: thread,
                conversation: conversation,
                change: .counted(messages: 3, unread: 1)
            )
        ] + rows.map { .upsertMessage($0) })
        #expect(try ids(in: store) == ["newest-reply"])
    }

    @Test func anUnreadFlagWithoutAPositionWaitsForTheConfirmedHead() throws {
        let store = try ChatStore.inMemory()
        let latest = message("latest", offset: 1)
        var room = Conversation(id: conversation, kind: .space, hasUnread: true)
        try store.apply([
            .setLocalMember(me), .replaceConversations([room]),
            .upsertMessage(message("cached-history", offset: -1))
        ])
        #expect(try ids(in: store).isEmpty)
        room.latestMainMessageAt = latest.createdAt
        try store.apply([.upsertConversation(room)])
        #expect(try ids(in: store).isEmpty)
        try store.apply([.upsertMessage(latest)])
        #expect(try ids(in: store) == ["latest"])
    }

    @MainActor
    @Test func flagOnlyHistoryLoadsOnePageAndDoesNotRestartOnReopenOrReconnect() async throws {
        let rows = (0 ... 3).map { message("message-\($0)", offset: Double($0)) }
        let world = unreadWorld(
            rows: rows,
            room: Conversation(
                id: conversation,
                kind: .space,
                hasUnread: true,
                latestMainMessageAt: rows.last?.createdAt
            )
        )
        let backend = RecordingBackend(world: world, pageSize: 1)
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: backend, store: store))
        try await model.start()
        model.showUnread()
        await settleAutoMarkRead(until: "the one inbox page is complete") {
            model.unreadWork.checked[conversation] != nil && !model.unreadHistoryLoading
                && model.unreadInbox?.messages == Array(rows.suffix(1))
        }
        #expect(await backend.historyCursors == [nil])

        model.showMentions()
        model.showUnread()
        await settleAutoMarkRead(until: "the reopened inbox is observed") { model.unreadInbox != nil }
        #expect(!model.unreadHistoryLoading)

        try store.apply([.setConnectionState(.reconnecting(attempt: 1, issue: nil, detail: nil))])
        await settleAutoMarkRead(until: "the reconnect is observed") {
            model.connectionState != .connected
        }
        try store.apply([.setConnectionState(.connected)])
        await settleAutoMarkRead(until: "the restored connection is observed") {
            model.actedOnConnection == .connected
        }
        #expect(!model.unreadHistoryLoading)
        #expect(await backend.historyCursors == [nil])

        try store.apply([.invalidateReplicaHistory])
        await settleAutoMarkRead(until: "the new replica epoch is checked") {
            await backend.loadMessagesCount == 2 && !model.unreadHistoryLoading
                && model.unreadInbox?.messages == Array(rows.suffix(1))
        }
        await model.stop()
    }

    @MainActor
    @Test func aReadReceiptCancelsAnOutstandingHistoryLoadAndKeepsTheInboxEmpty() async throws {
        let old = message("already-read", offset: -1)
        let latest = message("last-unread", offset: 1)
        let world = unreadWorld(
            rows: [old, latest],
            room: Conversation(
                id: conversation, kind: .space, hasUnread: true,
                readPosition: boundary, latestMainMessageAt: latest.createdAt
            )
        )
        let backend = RecordingBackend(world: world, pageSize: 1)
        await backend.holdHistory(true)
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: backend, store: store))
        try await model.start()
        try store.apply([.upsertMessage(old)])
        model.showUnread()
        await settleAutoMarkRead(until: "the inbox is waiting for the held request") {
            await backend.loadMessagesCount == 1 && model.unreadHistoryLoading
        }
        #expect(model.unreadInbox?.messages.isEmpty == true)

        try store.apply([.setReadState(conversation: conversation, lastReadAt: latest.createdAt, unread: 0)])
        await settleAutoMarkRead(until: "the receipt stops the inbox request") {
            !model.unreadHistoryLoading && model.unreadWork.history == nil
        }
        #expect(model.unreadInbox?.messages.isEmpty == true)
        #expect(await backend.historyCursors == [nil])
        await model.stop()
    }

    @MainActor
    @Test func anInboxReadForAFreshMessageStillWaitsBeforeSubmitting() async throws {
        let harness = try await makeAutoMarkReadHarness(markReadDebounce: .seconds(2))
        let id = autoMarkReadConversation
        let fresh = Message(
            id: .init("fresh"), conversationID: id, threadID: .init("fresh-thread"),
            sender: peer, text: "New message", createdAt: .now
        )
        harness.model.showUnread()
        harness.model.markUnreadMessagesRead([fresh], in: id)
        let pending = try #require(harness.model.markTasks[id])
        try await Task.sleep(for: .milliseconds(100))
        #expect(await markReadPositions(from: harness.backend).isEmpty)
        await harness.model.stop()
        await pending.value
        #expect(await markReadPositions(from: harness.backend).isEmpty)
    }

    @Test func individualReadsSurviveStoreReopenAndALaterUnreadMarkRestoresTheMessage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("inbox.sqlite").path
        let room = Conversation(id: conversation, kind: .space, hasUnread: true, readPosition: boundary)
        let earlier = message("earlier", offset: 1)
        let later = message("later", offset: 2)
        do {
            let store = try ChatStore.onDisk(at: path)
            try store.apply([
                .setLocalMember(me), .replaceConversations([room]),
                .upsertMessage(earlier), .upsertMessage(later)
            ])
            try store.markInboxMessageRead(MessageAddress(later))
        }
        let reopened = try ChatStore.onDisk(at: path)
        #expect(try ids(in: reopened) == ["earlier"])
        try reopened.apply([.setReadState(
            conversation: conversation,
            lastReadAt: earlier.createdAt,
            unread: 1
        )])
        #expect(try ids(in: reopened).isEmpty)
        try reopened.apply([.setConversationUnreadMark(conversation: conversation, at: later.createdAt)])
        #expect(try ids(in: reopened) == ["later"])
    }

    private func ids(in store: ChatStore) throws -> [String] {
        try store.database.read(ChatStore.fetchUnreadInbox).messages.map(\.id.rawValue)
    }
}

extension UnreadInboxTests {
    @MainActor
    @Test func aFailedHistoryRequestStopsLoadingUntilRetry() async throws {
        let latest = message("unread", offset: 1)
        let world = unreadWorld(
            rows: [latest],
            room: Conversation(
                id: conversation,
                kind: .space,
                hasUnread: true,
                latestMainMessageAt: latest.createdAt
            )
        )
        let backend = RecordingBackend(world: world)
        await backend.failHistory(true)
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: backend, store: store))
        try await model.start()
        model.showUnread()
        await settleAutoMarkRead(until: "the failed page has finished") {
            model.unreadHistoryFailed && !model.unreadHistoryLoading
        }
        #expect(await backend.historyCursors == [nil])

        await backend.failHistory(false)
        model.retryUnreadHistory()
        await settleAutoMarkRead(until: "the retry has loaded the unread message") {
            model.unreadInbox?.messages == [latest] && !model.unreadHistoryLoading
        }
        #expect(!model.unreadHistoryFailed)
        #expect(await backend.historyCursors == [nil, nil])
        await model.stop()
    }
}

extension UnreadInboxTests {
    func unreadWorld(rows: [Message], room: Conversation) -> FixtureWorld {
        FixtureWorld(
            me: me, members: [Member(id: me, kind: .human), Member(id: peer, kind: .human)],
            conversations: [room], messages: rows, startedAt: boundary.addingTimeInterval(7)
        )
    }
}
