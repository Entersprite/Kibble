import ChatKit
import ChatPersistence

extension ChatSessionModel {
    func watchReplicaHistory() {
        var previous: Int64?
        watch(store.observeReplicaHistoryEpoch()) { [weak self] epoch in
            defer { previous = epoch }
            guard let previous, previous != epoch else { return }
            self?.refreshAfterReplicaSnapshot()
        }
    }

    private func refreshAfterReplicaSnapshot() {
        cancelUnverifiedReadMarks()
        if threads.showingList {
            threads.work.listTask?.cancel()
            threads.work.listTask = Task { [engine] in await engine.requestFollowedThreads() }
        }
        guard let selected else { return }
        let thread = threads.openThread
        historyTask?.cancel()
        messages = []
        meetingWork.exhausted = []
        meetingWork.visible = []
        resetTranscript()
        observeTranscript(in: selected, request: .latest(100))
        refreshLatestTranscript(in: selected)
        if let thread {
            closeThread()
            openThread(thread)
        }
    }

    private func cancelUnverifiedReadMarks() {
        for task in markTasks.values {
            task.cancel()
        }
        markTasks = [:]
        let threadMarks = Array(threads.work.markTasks.values) + threads.work.superseded
        for task in threadMarks {
            task.cancel()
        }
        threads.work.markTasks = [:]
        threads.work.superseded = []
        threads.work.submittedGeneration = [:]
        // Generation counters survive cancellation; a late completion must not
        // retire a replacement mark created after the fresh history arrives.
    }
}
