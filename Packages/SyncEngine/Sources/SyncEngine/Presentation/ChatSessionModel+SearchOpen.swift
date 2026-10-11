import ChatKit
import Foundation

/// Search's opening half (search spec §1.3, §1.4): a hit, a conversation, a
/// person; the bar's steps.
public extension ChatSessionModel {
    func openSearchResult(_ id: Message.ID) {
        guard let answered = search.answered, let index = search.hits.firstIndex(where: { $0.id == id })
        else { return }
        cancelBarPage()
        var state = search
        state.bar = SearchBarState(query: answered, hits: state.hits, next: state.next, index: index)
        state.isShown = false
        // A list page out now is canceled with the rest; the bar keeps its cursor.
        state.isLoadingMore = false
        let text = answered.text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            Task { [engine] in await engine.recordSearch(text) }
        }
        openHit(state.hits[index], from: state)
    }

    func openSearchConversation(_ id: Conversation.ID) {
        searchWork.openTask?.cancel()
        searchWork.openTask = nil
        cancelBarPage()
        var state = search
        state.isShown = false
        state.bar = nil
        state.highlight = nil
        search = state
        select(id)
    }

    /// Their direct message if there is one; otherwise their messages.
    func openSearchPerson(_ id: Member.ID) {
        if let dm = conversations.first(where: { $0.kind == .directMessage && $0.members.contains(id) }) {
            openSearchConversation(dm.id)
            return
        }
        var query = search.query
        query.text = ""
        query.from = id
        runSearch(query, debounced: false)
    }

    /// The bar's ‹ and ›. Past the last loaded hit, the next page first.
    func stepSearchResult(by step: Int) {
        guard let bar = search.bar else { return }
        let target = bar.index + step
        if target == bar.hits.count, let cursor = bar.next {
            loadBarPage(after: cursor, thenOpen: target)
            return
        }
        guard bar.hits.indices.contains(target) else { return }
        // A step to a loaded hit wins over a page still out for a later one.
        cancelBarPage()
        var state = search
        state.bar?.index = target
        openHit(bar.hits[target], from: state)
    }

    func endSearch() {
        searchWork.openTask?.cancel()
        searchWork.openTask = nil
        cancelBarPage()
        var state = search
        state.bar = nil
        state.highlight = nil
        search = state
    }
}

extension ChatSessionModel {
    /// Opens a hit where it lives: the transcript, or its thread for a reply
    /// (`open(conversation:message:)`'s rule), after paging history back until
    /// it is stored. `state` is the caller's pending change, written here in
    /// the same one mutation.
    func openHit(_ hit: Message, from state: SearchSessionState) {
        searchWork.openTask?.cancel()
        searchWork.openTask = nil
        var state = state
        state.highlight = nil
        guard conversations.contains(where: { $0.id == hit.conversationID }) else {
            state.bar?.isOpening = false
            state.bar?.unreachable = true
            search = state
            return
        }
        state.bar?.unreachable = false
        state.bar?.isOpening = true
        search = state
        if selected != hit.conversationID {
            select(hit.conversationID)
        }
        let limit = searchWork.historyPageLimit
        searchWork.openTask = Task { @MainActor [weak self, engine] in
            let found = await (try? engine.loadHistory(
                in: hit.conversationID,
                until: hit.id,
                pageLimit: limit
            ))
                ?? false
            guard !Task.isCancelled, let self else { return }
            var state = search
            state.bar?.isOpening = false
            // The person went elsewhere while history paged: stay there.
            guard selected == hit.conversationID else {
                search = state
                return
            }
            guard found else {
                state.bar?.unreachable = true
                search = state
                return
            }
            open(conversation: hit.conversationID, message: hit.id)
            state.highlight = hit.id
            search = state
        }
    }

    private func cancelBarPage() {
        searchWork.pageTask?.cancel()
        searchWork.pageTask = nil
    }

    private func loadBarPage(after cursor: MessageSearchCursor, thenOpen target: Int) {
        guard let query = search.bar?.query else { return }
        searchWork.pageTask?.cancel()
        searchWork.pageTask = Task { @MainActor [weak self, engine] in
            let page = try? await engine.searchMessages(query, after: cursor)
            guard !Task.isCancelled, let self else { return }
            guard let page, var bar = search.bar, bar.query == query else { return }
            let known = Set(bar.hits.map(\.id))
            bar.hits += page.hits.filter { !known.contains($0.id) }
            bar.next = page.next
            var state = search
            guard bar.hits.indices.contains(target) else {
                state.bar = bar
                search = state
                return
            }
            bar.index = target
            state.bar = bar
            openHit(bar.hits[target], from: state)
        }
    }
}
