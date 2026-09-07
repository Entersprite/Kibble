import ChatKit
import Foundation

// MARK: - The automatic mark-read trigger

/// Split out of `ChatSessionModel.swift` to keep that file under swiftlint's
/// `file_length` ceiling (`CLAUDE.md`'s own precedent - `LiveChannelTests.swift`
/// was split for the same reason - is to split a file rather than trim a doc
/// comment to fit).
///
/// `published`, `markTasks`, `markGeneration` and `engine` are declared in
/// `ChatSessionModel.swift` without `private` (plain `internal`) specifically
/// so this extension - in a different file, where Swift's same-file `private`
/// visibility does not reach - can read and write them. `isActive` is
/// `public internal(set)` for the same reason: the public surface is
/// unchanged either way, since nothing outside this module could see past
/// `private` or `internal` regardless.
extension ChatSessionModel {
    /// Told by the app shell whether the app is frontmost.
    ///
    /// Becoming frontmost marks the open conversation, because otherwise
    /// everything that arrived while the user was away stays unread until a
    /// *new* message happens to arrive and trigger it.
    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            markSelectedReadIfNeeded()
        }
    }

    /// Publishes a read position for the open conversation, if all of these
    /// hold: the app is frontmost, the backend can mark read, something is
    /// open, that conversation has a message, its newest position is beyond
    /// what has already been published, and no mark is in flight for it.
    ///
    /// Ghost mode is not checked here. It is enforced in
    /// `SyncEngine.submit(_:)`, which is the single chokepoint by design - a
    /// second check here would be a second place to forget.
    func markSelectedReadIfNeeded() {
        guard isActive, capabilities.canMarkRead, let selected else { return }
        // `max` rather than `messages.last`, so the trigger does not depend on
        // the observation's ordering.
        guard let newest = messages.map(\.createdAt).max() else { return }
        if let already = published[selected], newest <= already {
            return
        }
        guard markTasks[selected] == nil else { return }
        // Captured now, before the task below can install a replacement of
        // its own: this is the value both clear sites compare against, so
        // each mark only ever erases the entry it itself installed. See
        // `markGeneration`'s doc comment for what goes wrong without it.
        let generation = (markGeneration[selected] ?? 0) + 1
        markGeneration[selected] = generation
        markTasks[selected] = Task { @MainActor [weak self, engine] in
            // Must be `defer`, not a plain statement after the last use of
            // `self`: any early return added later here - a
            // `Task.checkCancellation()` above `submit`, say - would
            // otherwise leave this conversation's key in `markTasks`
            // forever, wedging every later trigger for it. The badge would
            // then never clear again for the life of the session, which is
            // worse than the bug this task exists to fix.
            defer { self?.clearMarkTask(for: selected, ifStillGeneration: generation) }
            let accepted = await engine.submit(.markRead(
                conversationID: selected, upTo: newest
            ))
            guard let self, !Task.isCancelled else { return }
            // Only on success, and only if this mark was not cancelled out
            // from under it - `stop()` cancels every entry in `markTasks` on
            // sign-out, and a cancelled mark must not advance the watermark
            // for a conversation that may not even exist in this store any
            // more. A failure leaves the watermark where it was so the next
            // open, the next message or the next return to frontmost tries
            // again - there is no retry loop of its own.
            if accepted {
                published[selected] = newest
            }
            // Cleared here, ahead of the `defer` above, rather than left to
            // it: the recursive re-check just below calls back into
            // `markSelectedReadIfNeeded()`, whose own in-flight guard reads
            // this same dictionary. A `defer` only runs once this closure
            // returns, which is *after* that recursive call already ran - so
            // leaving the clear to `defer` alone made the guard see this
            // conversation as still in flight and silently suppress its own
            // re-check, every time. The `defer` stays, for every early return
            // above this line. Both clears go through `clearMarkTask`, which
            // only clears if `generation` is still the one installed - see
            // its doc comment for why an unconditional clear at either site
            // corrupts a re-armed mark's own tracking.
            clearMarkTask(for: selected, ifStillGeneration: generation)
            // A delivery that arrived while this mark was in flight was
            // suppressed by the `markTasks[selected] == nil` guard above and
            // never re-checked on its own - without this, the last message of
            // a burst is exactly the one that never gets marked, because no
            // later message ever arrives to trigger it again. Re-running the
            // whole check, rather than resubmitting directly, re-validates
            // focus, capability and selection from scratch instead of
            // assuming nothing changed while this awaited. Comparing against
            // a freshly computed newest - not resubmitting unconditionally -
            // is what keeps this from looping forever against a failing
            // backend: on failure `published` stays unadvanced, but the
            // freshly computed newest is unchanged too, so this condition is
            // false and there is no retry loop here.
            if let freshest = messages.map(\.createdAt).max(), freshest > newest {
                markSelectedReadIfNeeded()
            }
        }
    }

    /// Clears `markTasks[conversation]`, but only if `markGeneration` still
    /// names `generation` as the one installed there - see `markGeneration`'s
    /// doc comment. Both clear sites in `markSelectedReadIfNeeded` go through
    /// this rather than assigning `nil` directly, so neither can ever erase a
    /// later mark's own entry.
    func clearMarkTask(for conversation: Conversation.ID, ifStillGeneration generation: Int) {
        guard markGeneration[conversation] == generation else { return }
        markTasks[conversation] = nil
    }
}
