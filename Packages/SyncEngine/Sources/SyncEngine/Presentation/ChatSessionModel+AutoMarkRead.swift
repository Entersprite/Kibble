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
    /// `store.observeConversations()`'s handler, moved here from `start()` so
    /// `ChatSessionModel.swift` stays a one-line `watch(...)` call - the same
    /// `file_length` reasoning that put this whole extension in its own file.
    /// This is why `conversations` is `internal(set)` rather than
    /// `private(set)`, same as `isActive`.
    func conversationsObserved(_ conversations: [Conversation]) {
        self.conversations = conversations
        markReadTrace?.conversationsChanged(conversations)
    }

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

    /// `markSelectedReadIfNeeded()`'s own tracing call, factored out to a
    /// proper method rather than a nested function so that function stays
    /// under swiftlint's `function_body_length` ceiling. A `nil`
    /// `markReadTrace` (every ordinary launch) makes this a single pointer
    /// check and nothing else, exactly `ChannelTraceSink`'s own contract,
    /// which is why the filtered message list is recomputed here rather than
    /// taken as a parameter.
    ///
    /// **`conversation` and `position` exist because the debounce put a
    /// suspension point between the decision and the row.** Every emission
    /// used to be synchronous inside the trigger, so reading `selected` and
    /// `messages` fresh always described the thing being decided about.
    /// After the wait it does not: `selected` may name a different
    /// conversation by then, and a `submitted` row that reported the *new*
    /// conversation's id and the *new* conversation's newest age, paired with
    /// a `markOutcome` row naming the old one, is a verdict computed off a
    /// broken instrument - `findings.md` §12.2's failure mode with a
    /// different input, and the live verification of the debounce reads
    /// `newestAgeSeconds` off exactly that row. So the post-wait half passes
    /// in what it is actually acting on. Both stay defaulted, so the
    /// pre-wait call sites are unchanged and still report live state, which
    /// for them is the same thing.
    ///
    /// `position` is a *position*, reported as an age measured now - for a
    /// `submitted` row that is the age of the position being published,
    /// which is the number the debounce is verified against.
    ///
    /// `loadedMessageCount` and `filteredMessageCount` are deliberately
    /// still live readings of `messages`, because their own doc comments
    /// define them as "loaded for the open conversation at the moment of
    /// this evaluation". After a switch mid-wait they therefore describe the
    /// newly-open conversation rather than `conversation`. Left as is: they
    /// are non-optional on the wire, so there is nothing honest to put there
    /// instead, and unlike `newestAgeSeconds` nothing computes a verdict
    /// from them.
    private func traceTrigger(
        _ outcome: MarkReadTriggerOutcome,
        for conversation: Conversation.ID? = nil,
        publishing position: Date? = nil
    ) {
        guard let markReadTrace else { return }
        let subject = conversation ?? selected
        let filtered = messages.filter { !$0.id.rawValue.hasPrefix("local/") }
        let newest = position ?? filtered.map(\.createdAt).max()
        let unreadCount = subject.flatMap { id in conversations.first { $0.id == id }?.unreadCount }
        markReadTrace.triggerEvaluated(
            conversation: subject,
            outcome: outcome,
            context: MarkReadTriggerContext(
                loadedMessageCount: messages.count,
                filteredMessageCount: filtered.count,
                newestAgeSeconds: newest.map { Date().timeIntervalSince($0) },
                unreadCount: unreadCount
            )
        )
    }

    /// *Schedules* a read position for the open conversation, if all of these
    /// hold: the app is frontmost, the backend can mark read, something is
    /// open, that conversation has a message, its newest position is beyond
    /// what has already been published, and no mark is in flight for it.
    ///
    /// Scheduled rather than sent, since the debounce: `markReadDebounce`
    /// elapses first and `publishReadPosition(for:scheduledAt:generation:)`
    /// re-checks the guards that a two-second wait is long enough to
    /// invalidate before anything reaches the backend.
    ///
    /// Ghost mode is not checked here. It is enforced in
    /// `SyncEngine.submit(_:)`, which is the single chokepoint by design - a
    /// second check here would be a second place to forget.
    func markSelectedReadIfNeeded() {
        // Split from the original single compound guard
        // (`isActive, capabilities.canMarkRead, let selected`) into three,
        // in the same order, so `traceTrigger(_:)` can name which one declined -
        // behaviourally identical, since a comma-separated guard already
        // short-circuits left to right exactly like three guards in a row.
        guard isActive else { traceTrigger(.notFrontmost); return }
        guard capabilities.canMarkRead else { traceTrigger(.cannotMarkRead); return }
        guard let selected else { traceTrigger(.nothingSelected); return }
        // `max` rather than `messages.last`, so the trigger does not depend on
        // the observation's ordering. Excludes this file's own `local/`-
        // prefixed optimistic rows (see `send(_:)`): they carry `Date()`, not
        // a server-known position, so a conversation holding only local rows
        // has nothing to publish, and a send must not, by itself, publish a
        // read position. Filtered on the **id** prefix, not `localID` - the
        // server echoes `localID` back onto the real message, which does have
        // a genuine server position and must still count.
        guard let newest = messages
            .filter({ !$0.id.rawValue.hasPrefix("local/") })
            .map(\.createdAt).max()
        else {
            traceTrigger(.noServerMessages)
            return
        }
        if let already = published[selected], newest <= already {
            traceTrigger(.watermarkNotAdvanced)
            return
        }
        guard markTasks[selected] == nil else { traceTrigger(.alreadyInFlight); return }
        // `.scheduled`, not `.submitted`: all this call has decided is that a
        // mark will happen. The row that says one was actually sent follows
        // when the wait below ends and the guards still hold, and a capture
        // showing `scheduled` with nothing after it says the wait was
        // abandoned - the row after it says why.
        traceTrigger(.scheduled)
        // Captured now, before the task below can install a replacement of
        // its own: this is the value both clear sites compare against, so
        // each mark only ever erases the entry it itself installed. See
        // `markGeneration`'s doc comment for what goes wrong without it.
        let generation = (markGeneration[selected] ?? 0) + 1
        markGeneration[selected] = generation
        markTasks[selected] = Task { @MainActor [weak self, debounce = markReadDebounce] in
            // Must be `defer`, not a plain statement after the last use of
            // `self`: every early return below - and the wait adds several,
            // in `publishReadPosition` as well as here - would otherwise
            // leave this conversation's key in `markTasks` forever, wedging
            // every later trigger for it. The badge would then never clear
            // again for the life of the session, which is worse than the bug
            // this task exists to fix. It covers `publishReadPosition`'s
            // returns too, because that call is the last thing this closure
            // does.
            defer { self?.clearMarkTask(for: selected, ifStillGeneration: generation) }
            do {
                // `markReadDebounce`'s doc comment is why this exists at
                // all. Nothing else here waits, and this one must not be
                // "simplified" away.
                try await Task.sleep(for: debounce)
            } catch {
                // Cancelled mid-wait: `stop()` on sign-out, or this entry
                // being replaced. Not a decision the trigger made about
                // state, so it gets its own token rather than borrowing a
                // guard's.
                self?.traceTrigger(.cancelledDuringWait, for: selected, publishing: newest)
                return
            }
            // Deliberately **not** `[weak self, engine]` any more: a model
            // torn down during the wait must publish nothing at all, and
            // capturing `engine` strongly would let it submit for an account
            // `stopAndEraseStore()` has already signed out of - the exposure
            // `markTasks`' own doc comment names.
            guard let self else { return }
            await publishReadPosition(
                for: selected, scheduledAt: newest, generation: generation
            )
        }
    }

    /// The half of a mark that runs after the wait.
    ///
    /// Re-checks the guards that two seconds is long enough to invalidate -
    /// focus, capability and the watermark - but **not** the in-flight guard,
    /// because this task *is* that entry.
    ///
    /// `scheduledAt` is the position that would have been published when the
    /// wait began, and it is the fallback for one specific case: after the
    /// wait, `messages` belongs to whatever is selected *now*, so recomputing
    /// from it once the user has switched conversations would publish another
    /// conversation's timestamp against this conversation's id. `max` of the
    /// two is always safe and makes both paths converge.
    ///
    /// Recomputing rather than reusing `scheduledAt` is the whole point of
    /// the wait: everything that arrived while it ran is covered by this one
    /// position, so a burst produces one call instead of one per message.
    ///
    /// **The cancellation check at the head is not the same one as the check
    /// before the watermark write, and both are needed.** `Task.sleep`
    /// returns *normally* when its timer has already fired, so `stop()`
    /// landing in the sliver between the timer firing and the task resuming
    /// leaves this function entered by a cancelled task with every guard
    /// still passing - and it would issue a `mark_group_readstate` for an
    /// account being signed out of. The store-write half of that is already
    /// closed one layer down (`SyncEngine.submit(_:)` checks before it
    /// records), so what this removes is an avoidable HTTP request rather
    /// than a corrupt write. The check at `:246` stays because it guards a
    /// different window: cancellation arriving *during* the submit, which
    /// this one cannot see. Returning here still clears the tracking entry,
    /// because the caller's `defer` is installed before the wait and this
    /// call is the last statement of that closure.
    private func publishReadPosition(
        for conversation: Conversation.ID,
        scheduledAt: Date,
        generation: Int
    ) async {
        guard !Task.isCancelled else { return }
        guard isActive else {
            traceTrigger(.notFrontmost, for: conversation, publishing: scheduledAt)
            return
        }
        guard capabilities.canMarkRead else {
            traceTrigger(.cannotMarkRead, for: conversation, publishing: scheduledAt)
            return
        }
        let position: Date
        if selected == conversation {
            let recomputed = messages
                .filter { !$0.id.rawValue.hasPrefix("local/") }
                .map(\.createdAt).max()
            position = max(scheduledAt, recomputed ?? scheduledAt)
        } else {
            position = scheduledAt
        }
        if let already = published[conversation], position <= already {
            traceTrigger(.watermarkNotAdvanced, for: conversation, publishing: position)
            return
        }
        traceTrigger(.submitted, for: conversation, publishing: position)
        let startedAt = ContinuousClock.now
        let accepted = await engine.submit(.markRead(
            conversationID: conversation, upTo: position
        ))
        markReadTrace?.markOutcome(
            conversation: conversation, accepted: accepted, duration: ContinuousClock.now - startedAt
        )
        // Only on success, and only if this mark was not cancelled out from
        // under it - `stop()` cancels every entry in `markTasks` on sign-out,
        // and a cancelled mark must not advance the watermark for a
        // conversation that may not even exist in this store any more. A
        // failure leaves the watermark where it was so the next open, the
        // next message or the next return to frontmost tries again - there is
        // no retry loop of its own.
        guard !Task.isCancelled else { return }
        if accepted {
            published[conversation] = position
        }
        // Cleared here, ahead of the caller's `defer`, rather than left to
        // it: the recursive re-check just below calls back into
        // `markSelectedReadIfNeeded()`, whose own in-flight guard reads this
        // same dictionary. A `defer` only runs once that closure returns,
        // which is *after* this recursive call already ran - so leaving the
        // clear to `defer` alone made the guard see this conversation as
        // still in flight and silently suppress its own re-check, every
        // time. The `defer` stays, for every early return above this line.
        // Both clears go through `clearMarkTask`, which only clears if
        // `generation` is still the one installed - see its doc comment for
        // why an unconditional clear at either site corrupts a re-armed
        // mark's own tracking.
        clearMarkTask(for: conversation, ifStillGeneration: generation)
        // A delivery that arrived while this mark was in *flight* - after the
        // wait ended, not during it - was suppressed by the
        // `markTasks[selected] == nil` guard and never re-checked on its own.
        // The wait now coalesces the deliveries that used to land in that
        // window, but it does not close it: `engine.submit` is still an
        // await, and anything arriving inside it still hits that guard, so
        // without this the last message of a burst is exactly the one that
        // never gets marked. Re-running the whole check, rather than
        // resubmitting directly, re-validates focus, capability and selection
        // from scratch instead of assuming nothing changed.
        //
        // **The `local/` filter is what stops this looping against a failing
        // backend, and the filter is the load-bearing part rather than the
        // comparison.** The argument is that on failure `published` stays
        // unadvanced but the freshly computed newest is unchanged too, so the
        // condition is false and nothing is re-armed. That argument holds
        // only if this list is the same list `position` was computed from
        // two branches up - and until this filter was added it was not. An
        // optimistic send row (see `send(_:)`) carries `Date()` rather than a
        // server position and is excluded from the position, so an unfiltered
        // reading here made `freshest > position` permanently true for as
        // long as a send was unacknowledged: a failing mark then re-armed
        // itself forever, measured at 750 `mark_group_readstate` calls in
        // ~300ms with the interval at zero. This filter cannot suppress a
        // legitimate re-arm, because the re-arm exists to catch a *server*
        // message that landed during the submit and server ids carry no
        // `local/` prefix. Covered by
        // `MarkReadDebounceGuardSequenceTests.aFailedMarkWithAnUnackedLocalRowDoesNotLoop`.
        let freshest = messages
            .filter { !$0.id.rawValue.hasPrefix("local/") }
            .map(\.createdAt).max()
        if let freshest, freshest > position {
            markSelectedReadIfNeeded()
        }
    }

    /// Clears `markTasks[conversation]`, but only if `markGeneration` still
    /// names `generation` as the one installed there - see `markGeneration`'s
    /// doc comment. Both clear sites - the `defer` in
    /// `markSelectedReadIfNeeded`'s task and the explicit one in
    /// `publishReadPosition(for:scheduledAt:generation:)`, which must run
    /// before the re-arm - go through this rather than assigning `nil`
    /// directly, so neither can ever erase a later mark's own entry.
    func clearMarkTask(for conversation: Conversation.ID, ifStillGeneration generation: Int) {
        guard markGeneration[conversation] == generation else { return }
        markTasks[conversation] = nil
    }
}
