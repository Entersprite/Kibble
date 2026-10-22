import ChatKit
import ChatPersistence

public extension ChatSessionModel {
    func stop() async {
        browser.stop()
        for watcher in watchers + conversationWatchers {
            watcher.cancel()
        }
        watchers = []
        isClientTransportAvailable = true
        conversationWatchers = []
        // Cancelled, not joined: the request behind it may not itself be
        // abortable, and blocking `stop()` on a hung call would make sign-out
        // hang with it. `SyncEngine.loadMoreMessages`'s own cancellation
        // check is what actually stops it from writing whenever it does
        // return - see `historyTask`'s doc comment.
        activityWatchTask?.cancel()
        activityWatchTask = nil
        historyTask?.cancel()
        historyTask = nil
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
        resetTranscript()
        selectedMeetingSeries = nil
        isLoadingMeetingMetadata = false
        meetingWork.reset()
        store.releaseDecodedTranscripts()
        stopSearchAndReferences()
        // Same reasoning as `historyTask` just above: a mark in flight for an
        // account this call is signing out of must not be left to answer
        // into an erased store.
        for task in markTasks.values {
            task.cancel()
        }
        markTasks = [:]
        for task in reactionTasks.values {
            task.cancel()
        }
        reactionTasks = [:]
        reactionChainTail = nil
        for task in editTasks.values {
            task.cancel()
        }
        editTasks = [:]
        for task in sendTasks.values {
            task.cancel()
        }
        resetSubmissionWork()
        for task in conversationActionTasks.values {
            task.cancel()
        }
        conversationActionTasks = [:]
        conversationActionError = nil
        conversationActionGenerations = [:]
        unreadHolds = []
        composerFiles.reset()
        threads.stop()
        // Unreachable today - a fresh model is built per session - but a
        // stale watermark or a retained draft from the account being signed
        // out of must not survive into a model reused for the next sign-in.
        // `markGeneration` is deliberately **not** reset here: see its own
        // doc comment for the ABA a reset would reopen.
        published = [:]
        failed = nil
        await engine.stop()
    }

    private func stopSearchAndReferences() {
        directorySearch.reset()
        searchWork.reset()
        referenceWork.reset()
        search = SearchSessionState()
    }
}
