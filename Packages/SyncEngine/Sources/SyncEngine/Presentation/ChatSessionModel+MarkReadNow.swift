import ChatKit
import Foundation

extension ChatSessionModel {
    /// Marks one conversation read from outside the window - a notification's
    /// "Mark as Read" button.
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
    ///   conversation.
    /// - **The same watermark and the same per-conversation in-flight guard**
    ///   (`published`, `markTasks`, `markGeneration`), so a banner click and
    ///   an automatic mark for the same conversation cannot both submit.
    /// - **`SyncEngine.submit(_:)`**, so ghost mode still refuses at its one
    ///   chokepoint. In ghost mode this publishes nothing and the banner stays,
    ///   which is what ghost mode means.
    ///
    /// Not traced by `--probe=markread`: its vocabulary describes the automatic
    /// trigger's gates, and no exhaustive switch would force a new token to be
    /// emitted (`CLAUDE.md`, "a guard is not covered until...").
    public func markRead(_ conversation: Conversation.ID) {
        guard capabilities.canMarkRead else { return }
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
            await publishNewestPosition(in: conversation)
        }
    }

    private func publishNewestPosition(in conversation: Conversation.ID) async {
        let newest = ((try? store.messages(in: conversation)) ?? [])
            .filter { !$0.id.rawValue.hasPrefix("local/") }
            .map(\.createdAt).max()
        guard let newest else { return }
        if let already = published[conversation], newest <= already {
            return
        }
        let accepted = await engine.submit(.markRead(conversationID: conversation, upTo: newest))
        // As in the automatic trigger: a mark cancelled by `stop()` must not
        // advance the watermark of a session that is being torn down.
        guard !Task.isCancelled else { return }
        if accepted {
            published[conversation] = newest
        }
    }
}
