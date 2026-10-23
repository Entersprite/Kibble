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
        guard capabilities.canMarkRead, conversationActionTasks[conversation] == nil else { return }
        unreadHolds.remove(conversation)
        guard markTasks[conversation] == nil else { return }
        let generation = (markGeneration[conversation] ?? 0) + 1
        markGeneration[conversation] = generation
        markTasks[conversation] = Task { @MainActor [weak self, debounce = markReadDebounce] in
            // `defer` for the same reason the automatic trigger's is: every
            // early return must release the in-flight guard, or this
            // conversation can never be marked again this session.
            defer { self?.clearMarkTask(for: conversation, ifStillGeneration: generation) }
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await publishNewestPosition(in: conversation, from: origin)
        }
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
