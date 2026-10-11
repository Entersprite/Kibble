import ChatKit
import Foundation

/// Search's query half (search spec §3): sections at once, messages after a
/// pause, latest wins, then more pages on request.
public extension ChatSessionModel {
    func showSearch() {
        guard capabilities.canSearchMessages else { return }
        var state = search
        if let bar = state.bar {
            // Back to the list the bar came from, on the hit being read, and
            // nothing typed since may answer over it.
            searchWork.task?.cancel()
            searchWork.pageTask?.cancel()
            searchWork.peopleTask?.cancel()
            searchWork.inFlight = nil
            let words = SearchWords.of(bar.query.text)
            state.query = bar.query
            state.conversations = nameMatches(words, filtered: bar.query.hasFilters)
            state.people = knownPeople(words, filtered: bar.query.hasFilters)
            state.hits = bar.hits
            state.next = bar.next
            state.answered = bar.query
            state.focus = bar.hits.indices.contains(bar.index) ? bar.hits[bar.index].id : nil
            state.failed = false
            state.isSearching = false
            state.isLoadingMore = false
        }
        state.isShown = true
        search = state
        searchWork.recentsTask?.cancel()
        searchWork.recentsTask = Task { @MainActor [weak self, engine] in
            let recents = await engine.recentSearches(limit: ChatStore.searchRecentLimit)
            guard !Task.isCancelled, let self, search.isShown else { return }
            search.recents = recents
        }
    }

    func hideSearch() {
        search.isShown = false
    }

    func searchTextChanged(_ text: String) {
        var query = search.query
        query.text = text
        runSearch(query, debounced: true)
    }

    /// Filters and the order: everything but the text, which is kept.
    func setSearchQuery(_ query: MessageSearchQuery) {
        var query = query
        query.text = search.query.text
        runSearch(query, debounced: false)
    }

    func submitSearch() {
        runSearch(search.query, debounced: false)
    }

    func loadMoreSearchResults() {
        guard let cursor = search.next, !search.isLoadingMore, let answered = search.answered,
              answered == search.query
        else { return }
        search.isLoadingMore = true
        searchWork.pageTask = Task { @MainActor [weak self, engine] in
            let page = try? await engine.searchMessages(answered, after: cursor)
            guard !Task.isCancelled, let self else { return }
            var state = search
            state.isLoadingMore = false
            if let page, state.answered == answered {
                let known = Set(state.hits.map(\.id))
                state.hits += page.hits.filter { !known.contains($0.id) }
                state.next = page.next
            }
            search = state
        }
    }
}

extension ChatSessionModel {
    /// Sets `query`, updates the instant sections, and searches messages after
    /// the pause (`debounced`) or now.
    private func runSearch(_ query: MessageSearchQuery, debounced: Bool) {
        let words = SearchWords.of(query.text)
        let eligible = query.hasFilters || query.text.trimmingCharacters(in: .whitespaces).count >= 2
        // Return while this very query is on the wire: nothing to add.
        if !debounced, searchWork.inFlight == query, query == search.query {
            return
        }
        searchWork.task?.cancel()
        searchWork.pageTask?.cancel()
        searchWork.inFlight = nil
        var state = search
        state.query = query
        state.isLoadingMore = false
        state.conversations = nameMatches(words, filtered: query.hasFilters)
        // Known people now, in this one write; the directory's later.
        state.people = searchPeople(words: words, text: query.text, filtered: query.hasFilters)
        guard eligible, capabilities.canSearchMessages else {
            state.hits = []
            state.next = nil
            state.answered = nil
            state.isSearching = false
            state.failed = false
            search = state
            return
        }
        if state.answered == query, !state.failed {
            // Back to the answered query (typed away and back): its answer
            // stands, and nothing is out to clear `isSearching` later.
            state.isSearching = false
            search = state
            return
        }
        state.isSearching = true
        state.failed = false
        search = state
        requestMessages(query, debounced: debounced)
    }

    /// The message search itself, after the pause or now. Only the newest
    /// query's answer is published: a newer one cancels this task first.
    private func requestMessages(_ query: MessageSearchQuery, debounced: Bool) {
        let wait = debounced ? searchWork.debounce : .zero
        searchWork.task = Task { @MainActor [weak self, engine] in
            if wait > .zero {
                try? await Task.sleep(for: wait)
            }
            guard !Task.isCancelled else { return }
            self?.searchWork.inFlight = query
            let page: MessageSearchPage?
            do {
                page = try await engine.searchMessages(query, after: nil)
            } catch {
                page = nil
            }
            guard !Task.isCancelled, let self else { return }
            searchWork.inFlight = nil
            // Only the query on screen gets an answer: a reopen may have put
            // the bar's query back while this one was out.
            guard search.query == query else { return }
            var state = search
            state.hits = page?.hits ?? []
            state.next = page?.next
            state.answered = query
            state.isSearching = false
            state.failed = page == nil
            state.focus = nil
            search = state
        }
    }

    /// The known people matching, returned for the caller's one write, and
    /// the directory's merged in after the pause, three at most.
    private func searchPeople(words: [String], text: String, filtered: Bool) -> [Member] {
        searchWork.peopleTask?.cancel()
        searchWork.peopleTask = nil
        let known = knownPeople(words, filtered: filtered)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !filtered, !words.isEmpty, capabilities.canMentionNonMembers, trimmed.count >= 2 else {
            return known
        }
        let wait = searchWork.debounce
        searchWork.peopleTask = Task { @MainActor [weak self, engine] in
            if wait > .zero {
                try? await Task.sleep(for: wait)
            }
            guard !Task.isCancelled else { return }
            let found = await (try? engine.searchPeople(trimmed)) ?? []
            guard !Task.isCancelled, let self else { return }
            let ids = Set(known.map(\.id))
            search.people = Array((known + found.filter { !ids.contains($0.id) && $0.id != me }).prefix(3))
        }
        return known
    }

    /// Conversations whose name matches, three at most; none under a filter.
    func nameMatches(_ words: [String], filtered: Bool) -> [Conversation] {
        guard !filtered else { return [] }
        return Array(conversations.filter { SearchWords.match(searchTitle(of: $0), words) }.prefix(3))
    }

    /// Known people whose name matches, by name, three at most; none under a
    /// filter. Never you.
    func knownPeople(_ words: [String], filtered: Bool) -> [Member] {
        guard !filtered, !words.isEmpty else { return [] }
        let known = directory.values
            .filter { $0.id != me && SearchWords.match($0.displayName ?? "", words) }
            .sorted { ($0.displayName ?? "") < ($1.displayName ?? "") }
        return Array(known.prefix(3))
    }

    /// A conversation's name as the sidebar derives it, for matching only.
    func searchTitle(of conversation: Conversation) -> String {
        conversation.title ?? conversation.members.filter { $0 != me }
            .compactMap { directory[$0]?.displayName }.joined(separator: ", ")
    }
}
