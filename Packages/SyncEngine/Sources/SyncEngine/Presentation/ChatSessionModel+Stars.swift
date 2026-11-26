import ChatKit
import Foundation

public extension ChatSessionModel {
    func showStarredMessages() {
        guard capabilities.canStarMessages, !stars.showingList else { return }
        clearSelection()
        stars.showingList = true
        refreshStarredMessages()
    }

    func refreshStarredMessages() {
        guard stars.showingList, stars.pending.isEmpty else { return }
        if stars.isLoading {
            stars.needsRefresh = true
            return
        }
        loadStars(after: nil, depth: max(1, stars.pageCount))
    }

    func loadMoreStarredMessages() {
        guard stars.showingList, stars.pending.isEmpty, !stars.isLoading,
              let cursor = stars.nextCursor else { return }
        loadStars(after: cursor, depth: stars.pageCount + 1)
    }

    func setMessageStarred(_ starred: Bool, at address: MessageAddress) {
        guard capabilities.canStarMessages, isClientTransportAvailable,
              stars.pending.insert(address).inserted else { return }
        stars.cancelPage()
        stars.mutations[address] = Task { [weak self, engine] in
            let accepted = await (try? engine.setMessageStarred(starred, at: address)) != nil
            guard let self, !Task.isCancelled else { return }
            stars.mutations[address] = nil
            stars.pending.remove(address)
            if accepted {
                stars.setKnownStar(starred, at: address)
            } else {
                lastError = .unknown("The star change could not be confirmed.")
            }
            refreshStarredMessages()
        }
    }
}

extension ChatSessionModel {
    private func loadStars(after cursor: String?, depth: Int) {
        stars.cancelPage()
        let id = stars.pageID
        let appending = cursor != nil
        let count = appending ? 1 : depth
        let visited = appending ? stars.visitedCursors : []
        stars.readFailed = false
        stars.isLoading = true
        stars.pageTask = Task { [weak self, engine] in
            let pages = try? await engine.starredMessages(after: cursor, pages: count, visited: visited)
            guard let self, !Task.isCancelled, stars.pageID == id, stars.showingList else { return }
            stars.pageTask = nil
            stars.isLoading = false
            if stars.needsRefresh {
                loadStars(after: nil, depth: depth)
                return
            }
            guard let pages else {
                stars.readFailed = true
                return
            }
            stars.accept(pages, appending: appending)
        }
    }
}
