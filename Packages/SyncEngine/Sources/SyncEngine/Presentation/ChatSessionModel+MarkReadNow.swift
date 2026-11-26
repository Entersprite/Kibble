import ChatKit
import ChatPersistence
import Foundation

/// Which "Mark as Read" was pressed, because the two trust the store
/// differently.
public enum MarkReadOrigin: Sendable, Equatable {
    /// A banner's button. The banner's message arrived live and was stored
    /// before the banner was posted, so the newest stored message is the one
    /// the banner shows, and nothing is fetched unless nothing is stored.
    case notification

    /// The sidebar's or a menu's item. The newest stored message can be stale
    /// here: launch reloads conversations only, so messages that arrived while
    /// Kibble was quit are not stored until the conversation is opened, and a
    /// row migrated from the millisecond store can sit up to half a
    /// millisecond below its message (`findings.md` §42.1). A mark short of
    /// Google's head is accepted, clears the dot, and comes back unread on the
    /// next relaunch, so this origin always fetches the newest page first.
    case conversationList
}

extension ChatSessionModel {
    /// Marks one conversation read from outside the window - a notification's
    /// "Mark as Read" button, **or the sidebar's** (`origin` says which).
    ///
    /// `markSelectedReadIfNeeded()` cannot serve this: its first two gates are
    /// "the app is frontmost" and "this conversation is selected", and a
    /// banner button is pressed from Notification Center with neither true.
    /// Everything else is shared with the automatic trigger on purpose:
    ///
    /// - **The `markReadDebounce` wait first.** `findings.md` §36.7: a
    ///   position published within a moment of its message arriving does not
    ///   register. A click is usually seconds after arrival, but a second
    ///   message can land just before it, so the wait is not skipped.
    /// - **The newest *server* message the store holds**, never a `local/`
    ///   optimistic row, recomputed after the wait - read from the store
    ///   rather than `messages`, which only ever holds the *selected*
    ///   conversation - or the conversation's newest main message when no
    ///   stored message is that new.
    /// - **The same watermark and the same per-conversation in-flight guard**
    ///   (`published`, `markTasks`, `markGeneration`), so a banner click and
    ///   an automatic mark for the same conversation cannot both submit.
    /// - **`SyncEngine.submit(_:)`**, so the conversation's `readReceipts`
    ///   rule still refuses at its one chokepoint (`ReadReceiptGate`). With
    ///   receipts off this publishes nothing, and the refusal still withdraws
    ///   the conversation's banners locally (`SyncEngine.submit`'s local
    ///   `.read`). Such a notification offers no "Mark as Read" at all
    ///   (`MessageNotification.offersMarkRead`, in `AppCore`), and the
    ///   sidebar hides it for such a row, because the button would tell
    ///   Google nothing.
    /// - **The newest page first**, always for `.conversationList` and, for
    ///   `.notification`, only when nothing is stored - a sidebar mark can
    ///   reach a conversation never opened this session, or one whose stored
    ///   newest is behind Google's (`MarkReadOrigin`). A failed fetch falls
    ///   back to the newest stored message, and is recorded where the window
    ///   shows it; with nothing stored either, nothing is published.
    /// - **The conversation's unread threads too**, for `.conversationList`
    ///   only, after its own mark and with the panel's calls
    ///   (`markUnreadThreadsRead(in:)`), inside the same in-flight guard.
    ///
    /// Not traced by `--probe=markread`: its vocabulary describes the automatic
    /// trigger's gates, and no exhaustive switch would force a new token to be
    /// emitted (`CLAUDE.md`, "a guard is not covered until...").
    public func markRead(_ conversation: Conversation.ID, from origin: MarkReadOrigin) {
        scheduleExplicitRead(in: conversation) { model in
            await model.publishNewestPosition(in: conversation, from: origin)
        }
    }

    /// Takes the rows and any conversation head captured by the inbox.
    /// Only the newest included position can still need time to settle.
    public func markUnreadMessagesRead(
        _ messages: [Message], in conversation: Conversation.ID, through capturedHead: Date? = nil
    ) {
        guard showingUnread, conversations.contains(where: { $0.id == conversation }) else { return }
        let here = messages.filter { $0.conversationID == conversation }
        guard !here.isEmpty || capturedHead != nil else { return }
        let target = InboxReadTarget(messages: here, head: capturedHead)
        scheduleExplicitRead(in: conversation, delay: inboxReadDelay(through: target.latest)) { model in
            await model.publishInboxRead(target, in: conversation)
        }
    }

    func inboxReadDelay(through latest: Date?) -> Duration {
        guard let latest else { return .zero }
        let age = max(0, Date.now.timeIntervalSince(latest))
        return max(.zero, markReadDebounce - .seconds(age))
    }

    func publishInboxRead(_ target: InboxReadTarget, in conversation: Conversation.ID) async {
        guard !Task.isCancelled, conversations.contains(where: { $0.id == conversation }) else { return }
        if let main = target.main, let position = confirmedInboxPosition(through: main, in: conversation) {
            await submitConversationRead(through: position, in: conversation)
        }
        await markInboxThreadsRead(target.replies, in: conversation)
    }

    private func confirmedInboxPosition(through target: Date, in id: Conversation.ID) -> Date? {
        guard let row = try? store.conversation(id) else { return nil }
        guard let read = row.readPosition, target <= read else { return target }
        if row.markedUnreadAt != nil || (UnreadHistoryBasis(row).hasMainUnread &&
            (row.latestMainMessageAt ?? target) <= read) {
            return read
        }
        return nil
    }

    @discardableResult
    func scheduleExplicitRead(
        in conversation: Conversation.ID, delay: Duration? = nil,
        perform: @escaping @MainActor (ChatSessionModel) async -> Void
    ) -> Task<Void, Never>? {
        guard capabilities.canMarkRead, conversationActionTasks[conversation] == nil else { return nil }
        unreadHolds.remove(conversation)
        guard markTasks[conversation] == nil else { return nil }
        let generation = (markGeneration[conversation] ?? 0) + 1
        markGeneration[conversation] = generation
        let task = Task { @MainActor [weak self, wait = delay ?? markReadDebounce] in
            defer { self?.clearMarkTask(for: conversation, ifStillGeneration: generation) }
            do {
                try await Task.sleep(for: wait)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await perform(self)
        }
        markTasks[conversation] = task
        return task
    }

    private func publishNewestPosition(in conversation: Conversation.ID, from origin: MarkReadOrigin) async {
        var newest = newestServerMessage(in: conversation)
        if newest == nil || origin == .conversationList {
            // From the sidebar, a conversation unread since before launch may
            // never have been opened: none of its messages are stored, or
            // only those from before Kibble last quit. Its newest page first,
            // or this would publish nothing, or a position short of Google's
            // head. A failed fetch leaves the store as it was, so what is
            // stored is marked, and the failure is recorded where the window
            // shows it.
            await engine.requestMoreMessages(in: conversation, verifyCachedRoots: true)
            guard !Task.isCancelled else { return }
            newest = newestServerMessage(in: conversation)
        }
        await publishConversationPosition(through: newest, in: conversation)
        // The sidebar's mark reads the conversation's threads too, after the
        // newest page has brought their replies: a conversation's read does
        // not read its threads (`findings.md` §64.5). A banner names one
        // message, so it reads the conversation alone.
        guard origin == .conversationList, !Task.isCancelled else { return }
        await markUnreadThreadsRead(in: conversation)
    }

    /// The conversation's own mark, through its newest main message.
    private func publishConversationPosition(
        through newestStored: Date?,
        in conversation: Conversation.ID
    ) async {
        var newest = newestStored
        // Read means read through the conversation's newest main message,
        // including one no stored message is as new as: a mark short of it
        // would never clear the dot (`Conversation.markReadPosition(through:)`).
        if let row = conversations.first(where: { $0.id == conversation }) {
            newest = row.markReadPosition(through: newest)
        }
        guard let newest else { return }
        // A stale history page must not move Google's read position backward.
        // The automatic path makes this same check before publishing.
        let hasManualMark = (try? store.hasManualUnreadMark(in: conversation)) == true
        if !hasManualMark, skipsBehindServerPosition(newest, in: conversation) {
            return
        }
        if let already = published[conversation], newest <= already, !hasManualMark {
            return
        }
        await submitConversationRead(through: newest, in: conversation)
    }

    private func submitConversationRead(through newest: Date, in conversation: Conversation.ID) async {
        let position = readPositionClearingUnreadMark(newest, in: conversation)
        let accepted = await engine.submit(.markRead(conversationID: conversation, upTo: position))
        // As in the automatic trigger: a mark cancelled by `stop()` must not
        // advance the watermark of a session that is being torn down.
        guard !Task.isCancelled else { return }
        if accepted {
            published[conversation] = position
        }
    }

    private func newestServerMessage(in conversation: Conversation.ID) -> Date? {
        ((try? store.messages(in: conversation)) ?? [])
            .filter { !$0.id.rawValue.hasPrefix("local/") }
            .map(\.createdAt).max()
    }
}

struct InboxReadTarget: Sendable {
    var main: Date?
    var replies: [MessageThread.ID: Date]

    init(main: Date? = nil, replies: [MessageThread.ID: Date] = [:]) {
        self.main = main
        self.replies = replies
    }

    init(messages: [Message], head: Date?) {
        main = ([head] + messages.lazy.filter { !$0.isReply }.map(\.createdAt)).compactMap(\.self).max()
        replies = Dictionary(grouping: messages.filter(\.isReply), by: \.threadID)
            .compactMapValues { $0.map(\.createdAt).max() }
    }

    var latest: Date? {
        [main, replies.values.max()].compactMap(\.self).max()
    }
}
