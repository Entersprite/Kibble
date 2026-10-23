import ChatKit
import Foundation

// MARK: - The Calls row

/// The sidebar's Calls row and the list behind it: the account's retained
/// call records, newest first, a page at a time. Opening one goes to its
/// message in its conversation, as a mention opens.
public extension ChatSessionModel {
    /// Shows the Calls list, leaving no conversation selected
    /// (`clearSelection()`), and reads its first page again, so a call made
    /// since the list was last open is in it.
    func showCallHistory() {
        guard capabilities.canReadCallHistory, !callHistory.showingList else { return }
        clearSelection()
        callHistory.showingList = true
        loadCallHistoryPage(after: nil)
    }

    /// Reads the first page again, after it failed.
    func retryCallHistory() {
        guard callHistory.showingList else { return }
        loadCallHistoryPage(after: nil)
    }

    /// Reads the next page, once the first has arrived and while there is one.
    /// A later page that failed is asked for again here.
    func loadMoreCallHistory() {
        guard callHistory.showingList, callHistory.status == .loaded, !callHistory.isLoadingMore,
              let cursor = callHistory.nextCursor else { return }
        loadCallHistoryPage(after: cursor)
    }
}

extension ChatSessionModel {
    /// One page in flight at a time. A newer request, leaving the list or
    /// `stop()` moves the generation on, so an answer that arrives late for a
    /// list nobody is looking at, or for a session that ended, writes nothing.
    func loadCallHistoryPage(after cursor: String?) {
        callHistory.work.cancel()
        let generation = callHistory.work.generation
        let appending = cursor != nil
        if appending {
            callHistory.isLoadingMore = true
            callHistory.loadMoreFailed = false
        } else {
            callHistory.status = .loading
            callHistory.isLoadingMore = false
            callHistory.loadMoreFailed = false
        }
        let query = CallHistoryQuery(cursor: cursor, limit: CallHistorySessionState.pageSize)
        callHistory.work.task = Task { [weak self, engine] in
            let page: CallHistoryPage?
            do {
                page = try await engine.callHistory(query)
            } catch {
                page = nil
            }
            guard let self, !Task.isCancelled, callHistory.work.generation == generation,
                  callHistory.showingList else { return }
            callHistory.work.task = nil
            if let page {
                callHistory.apply(page, appending: appending)
            } else {
                callHistory.fail(appending: appending)
            }
        }
    }
}
