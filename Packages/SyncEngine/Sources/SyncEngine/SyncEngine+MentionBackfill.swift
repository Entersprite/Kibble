import ChatKit
import Foundation

// MARK: - The Mentions list's backfill

/// Google has no "messages that mention me" query (`findings.md` §44, the
/// Mentions spike). So after every world load this fetches one newest page
/// per recently active conversation and files it exactly as opening the
/// conversation does. The Mentions list is then a query over the store
/// (`ChatStore.mentionsOfMe`). The mentions-list spec §2.
///
/// Split from `SyncEngine.swift` for `file_length`. `mentionClock`,
/// `mentionBackfillTask` and `store` are declared there without `private` so
/// this file can reach them.
extension SyncEngine {
    /// Starts a run over the conversations the store holds now, and cancels a
    /// run still going. Called only after a world write has landed.
    ///
    /// **This `Task.isCancelled` is the event loop's.** This runs inside the
    /// consumer, and a world load that lands while `stop()` drains it must
    /// start nothing for a session being torn down, not even a status write.
    func startMentionBackfill() {
        guard let mentionClock, !Task.isCancelled else { return }
        mentionBackfillTask?.cancel()
        mentionBackfillTask = nil
        let candidates: [Conversation.ID]
        do {
            candidates = try MentionBackfill.candidates(in: store.conversations(), now: mentionClock())
        } catch {
            record(error)
            return
        }
        writeMentionBackfill(MentionBackfillStatus(running: !candidates.isEmpty))
        guard !candidates.isEmpty else { return }
        mentionBackfillTask = Task { [weak self] in
            await self?.runMentionBackfill(over: candidates)
        }
    }

    /// At most `MentionBackfill.maxInFlight` fetches at once, newest activity
    /// first.
    ///
    /// **A failure is counted for the pane's footer and never recorded:** no
    /// banner, and no retry within the run. The next world load tries it
    /// again (spec §2).
    ///
    /// **A run that is no longer current writes nothing.** Its pages are
    /// refused by `loadMoreMessages`' own cancellation check, its status by
    /// the check below, and `addTaskUnlessCancelled` starts no further fetch.
    private func runMentionBackfill(over candidates: [Conversation.ID]) async {
        let failed = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            var pending = candidates[...]
            var failed = 0
            for _ in 0 ..< MentionBackfill.maxInFlight {
                guard let next = pending.popFirst() else { break }
                _ = group.addTaskUnlessCancelled { await self.loadedNewestPage(of: next) }
            }
            for await loaded in group {
                if !loaded {
                    failed += 1
                }
                if let next = pending.popFirst() {
                    _ = group.addTaskUnlessCancelled { await self.loadedNewestPage(of: next) }
                }
            }
            return failed
        }
        guard !Task.isCancelled else { return }
        writeMentionBackfill(MentionBackfillStatus(running: false, failedConversations: failed))
    }

    /// Whether one conversation's newest page loaded and was filed.
    private func loadedNewestPage(of conversation: Conversation.ID) async -> Bool {
        do {
            try await loadMoreMessages(in: conversation)
            return true
        } catch {
            // Counted, never recorded: see `runMentionBackfill(over:)`.
            return false
        }
    }

    /// A store failure is recorded like any other (ruling 11). Only a
    /// *fetch* failure is counted rather than surfaced.
    private func writeMentionBackfill(_ status: MentionBackfillStatus) {
        do {
            try store.apply([.setMentionBackfill(status)])
        } catch {
            record(error)
        }
    }
}
