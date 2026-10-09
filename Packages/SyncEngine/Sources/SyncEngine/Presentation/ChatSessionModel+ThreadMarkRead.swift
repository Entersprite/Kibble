import ChatKit
import Foundation

// MARK: - Viewing a thread marks it read

/// The panel's automatic mark-read (threads spec §4.3): the conversation's
/// (`+AutoMarkRead.swift`) with the panel in place of the selection. The same
/// rules hold, for the same reasons, so read the doc comments on `published`,
/// `markTasks`, `markGeneration` and `markReadDebounce` in
/// `ChatSessionModel.swift` first. Everything they say holds here per thread,
/// in `ThreadWork`:
///
/// - the app frontmost, before the wait and after it;
/// - the panel showing the thread when the mark is scheduled;
/// - `markReadDebounce`'s wait, from the first trigger;
/// - the read-receipt gate, at `SyncEngine.submit(_:)`'s one chokepoint;
/// - a generation per thread, so a completing mark clears only its own entry;
/// - a watermark that advances only on success, and a re-check after the
///   submit for a reply that landed during it.
///
/// One difference: there is no watermark check after the wait. The in-flight
/// guard keeps any other mark for the thread from publishing during it, and
/// `markThreadUnread(from:)` cancels the waiting one instead, or supersedes
/// one already on the wire, whose answer then writes nothing.
///
/// It reads the newest *reply*, so a thread with nothing but its first
/// message has nothing to mark. Not traced by `--probe=markread`, for
/// `markRead(_:from:)`'s reason.
extension ChatSessionModel {
    /// *Schedules* a read position for the thread the panel shows, if the app
    /// is frontmost, a manual Mark as Unread has not turned it off, the thread
    /// has a reply with a server position beyond what has been published, and
    /// no mark is in flight for it.
    func markOpenThreadReadIfNeeded() {
        guard isActive, let selected, let thread = threads.openThread else { return }
        let key = ThreadKey(conversation: selected, thread: thread)
        // After a manual Mark as Unread the person is looking at a thread they
        // asked to keep unread, until the panel closes or shows another.
        guard threads.work.disarmed != key else { return }
        guard let newest = Self.newestServerReply(in: threads.messages) else { return }
        if let already = threads.work.published[key], newest <= already {
            return
        }
        guard threads.work.markTasks[key] == nil else { return }
        let generation = (threads.work.markGeneration[key] ?? 0) + 1
        threads.work.markGeneration[key] = generation
        threads.work.markTasks[key] = Task { @MainActor [weak self, debounce = markReadDebounce] in
            // `defer`, for the conversation trigger's reason: every early
            // return must release the in-flight guard.
            defer { self?.clearThreadMarkTask(for: key, ifStillGeneration: generation) }
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            // A model torn down during the wait publishes nothing.
            guard let self else { return }
            await publishThreadReadPosition(for: key, scheduledAt: newest, generation: generation)
        }
    }

    /// The half after the wait. `publishReadPosition`'s shape, with the clear
    /// that a thread marked unread needs first.
    private func publishThreadReadPosition(
        for key: ThreadKey, scheduledAt: Date, generation: Int
    ) async {
        guard !Task.isCancelled, isActive else { return }
        // Recomputed only while the panel still shows this thread. After a
        // switch, `threads.messages` is another thread's, and its newest must
        // never be published against this one's id.
        let recomputed = panelShows(key) ? Self.newestServerReply(in: threads.messages) : nil
        let position = max(scheduledAt, recomputed ?? scheduledAt)
        // From here the mark is on the wire: a Mark as Unread now waits for
        // its answer instead of canceling it (`markThreadUnread(from:)`).
        threads.work.submittedGeneration[key] = generation
        if (try? store.thread(key.thread, in: key.conversation))?.markedUnreadAt != nil {
            // Whether a read also clears a mark as unread on the server is
            // `[Verify]` (spec §3), so the clear goes first, and only when a
            // mark is set. A refused clear sends no read; the next trigger
            // tries both again.
            let cleared = await engine.submit(.setThreadUnreadMark(
                conversationID: key.conversation, threadID: key.thread, at: nil
            ))
            guard cleared, !Task.isCancelled else { return }
        }
        let accepted = await engine.submit(.markThreadRead(
            conversationID: key.conversation, threadID: key.thread, upTo: position
        ))
        guard !Task.isCancelled else { return }
        // Superseded on the wire by a Mark as Unread, which waits for this
        // answer: it writes no watermark, so a reopened thread is marked read
        // again, and it re-checks nothing.
        guard threads.work.markGeneration[key] == generation else { return }
        if accepted {
            threads.work.published[key] = position
        }
        // Cleared before the re-check, and through the generation, for the
        // conversation trigger's two reasons (`publishReadPosition`). The
        // re-check reads the same function the position came from, so an
        // unsent reply cannot make it loop, and only while the panel still
        // shows this thread: after a switch, `threads.messages` is another's.
        clearThreadMarkTask(for: key, ifStillGeneration: generation)
        if panelShows(key), let freshest = Self.newestServerReply(in: threads.messages),
           freshest > position {
            markOpenThreadReadIfNeeded()
        }
    }

    /// Whether the panel shows `key`'s thread now. After a switch,
    /// `threads.messages` is another thread's.
    private func panelShows(_ key: ThreadKey) -> Bool {
        selected == key.conversation && threads.openThread == key.thread
    }

    /// `clearMarkTask(for:ifStillGeneration:)`, per thread.
    func clearThreadMarkTask(for key: ThreadKey, ifStillGeneration generation: Int) {
        guard threads.work.markGeneration[key] == generation else { return }
        threads.work.markTasks[key] = nil
    }

    /// The newest reply with a server position: never the thread's first
    /// message, and never a `local/` optimistic reply, which carries `Date()`.
    private static func newestServerReply(in messages: [Message]) -> Date? {
        messages.filter { $0.isReply && !$0.id.rawValue.hasPrefix("local/") }.map(\.createdAt).max()
    }
}

// MARK: - Mark as Unread

public extension ChatSessionModel {
    /// Marks a thread unread from one of its messages: the panel's "Mark as
    /// Unread" on a reply (spec §5.2). It then keeps the thread unread while
    /// the panel shows it: auto-mark-read is off for that thread until the
    /// panel closes or shows another (spec §4.3).
    ///
    /// Three things make that hold:
    /// - a mark waiting for this thread is canceled, or its wait would end
    ///   with the thread read again;
    /// - the watermark forgets the thread, so reopening it marks it read
    ///   again rather than finding the position already published;
    /// - the unread mark waits for a mark already on the wire, so the server
    ///   sees the two in the order the person acted. It takes that mark's
    ///   place in `markTasks`, so no new read starts while it is in flight.
    ///
    /// **A mark on the wire is never canceled** (`submittedGeneration`).
    /// `URLSessionTransport` aborts a canceled task's request, so the wait
    /// would end when the client gave up, not when the server answered: this
    /// mark could reach the server first, and the aborted read would never be
    /// reported. Superseded instead, its answer writes nothing
    /// (`publishThreadReadPosition`), and it stays where `stop()` cancels it
    /// (`ThreadWork.superseded`). The same holds for an earlier unread mark
    /// still on the wire.
    ///
    /// `at` is the message's own time; the backend owns the wire's offset.
    /// Nothing for a message still sending (`local/`), which has no server time.
    func markThreadUnread(from message: Message) {
        guard capabilities.supportsThreads, !message.id.rawValue.hasPrefix("local/") else { return }
        let key = ThreadKey(conversation: message.conversationID, thread: message.threadID)
        let previous = threads.work.markTasks[key]
        if threads.work.submittedGeneration[key] != threads.work.markGeneration[key] {
            previous?.cancel()
        } else if let previous {
            // On the wire: left to answer, and kept where `stop()` reaches it.
            threads.work.superseded.append(previous)
        }
        threads.work.published[key] = nil
        if selected == key.conversation, threads.openThread == key.thread {
            threads.work.disarmed = key
        }
        let generation = (threads.work.markGeneration[key] ?? 0) + 1
        threads.work.markGeneration[key] = generation
        let command = ChatCommand.setThreadUnreadMark(
            conversationID: key.conversation, threadID: key.thread, at: message.createdAt
        )
        threads.work.markTasks[key] = Task { @MainActor [weak self] in
            defer { self?.clearThreadMarkTask(for: key, ifStillGeneration: generation) }
            // Not canceled with this task: a second click cancels a waiting
            // unread mark, and passing that on would abort the read on the wire.
            if let previous {
                await previous.value
                self?.threads.work.superseded.removeAll { $0 == previous }
            }
            guard let self, !Task.isCancelled else { return }
            threads.work.submittedGeneration[key] = generation
            await engine.submit(command)
            guard !Task.isCancelled else { return }
            // Before the re-check, which reads this entry: a panel reopened
            // while this was in flight found the thread busy, and is marked
            // read now, unless the hold still stands.
            clearThreadMarkTask(for: key, ifStillGeneration: generation)
            markOpenThreadReadIfNeeded()
        }
    }
}
