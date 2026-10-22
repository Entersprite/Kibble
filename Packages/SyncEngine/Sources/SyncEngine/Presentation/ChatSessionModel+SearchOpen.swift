import ChatKit
import ChatPersistence
import Foundation

/// Search's opening half (search spec §1.3, §1.4): a hit, a conversation, a
/// person; the bar's steps.
public extension ChatSessionModel {
    func openSearchResult(_ id: Message.ID) {
        guard let answered = search.answered, let index = search.hits.firstIndex(where: { $0.id == id })
        else { return }
        cancelBarPage()
        // A list page out now is canceled; the bar keeps its cursor.
        searchWork.pageTask?.cancel()
        searchWork.pageTask = nil
        var state = search
        state.bar = SearchBarState(query: answered, hits: state.hits, next: state.next, index: index)
        state.isShown = false
        state.isLoadingMore = false
        let text = answered.text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            recordSearch(text)
        }
        openHit(state.hits[index], from: state)
    }

    /// Edit › Next Result and Previous Result (⌘G, ⇧⌘G): only the bar, and
    /// never under the overlay, where the step would move the transcript
    /// behind the dim.
    var canStepSearch: Bool {
        search.bar != nil && !search.isShown
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

    /// Opens their direct message, restoring it when hidden or deleted.
    func openSearchPerson(_ id: Member.ID) {
        if let dm = conversations.first(where: { $0.kind == .directMessage && $0.members.contains(id) }) {
            openSearchConversation(dm.id)
            return
        }
        guard capabilities.canOpenDirectConversations else {
            var query = search.query
            query.text = ""
            query.from = id
            runSearch(query, debounced: false)
            return
        }
        openNewDirectConversation(with: id)
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
    /// (`open(conversation:message:)`'s rule), once the engine has asked for
    /// the history just before it, stored the hit with it and read where it
    /// lands (`SyncEngine.loadHistory(in:until:pageLimit:)`). `state` is the
    /// caller's pending change, written here in the same one mutation.
    ///
    /// Nothing here reads the store: pages are landing while a hit opens, and
    /// a read on the main thread waits for each of them (CLAUDE.md, session
    /// 66). That is why this does not call `open(conversation:message:)`.
    func openHit(_ hit: Message, from state: SearchSessionState) {
        searchWork.openTask?.cancel()
        searchWork.openTask = nil
        var state = state
        state.highlight = nil
        // Opening a hit, whatever it lands on, supersedes a stale "couldn't
        // load more": the bar has something more current to say now, if
        // anything. Cleared here, once, so every exit below (this guard's
        // `.notInSidebar`, the task's `.tooFarBack`, and the plain open)
        // inherits it rather than each needing its own.
        state.bar?.pageFailed = false
        guard conversations.contains(where: { $0.id == hit.conversationID }) else {
            state.bar?.isOpening = false
            state.bar?.unreachable = .notInSidebar
            search = state
            return
        }
        state.bar?.unreachable = nil
        state.bar?.isOpening = true
        search = state
        if selected != hit.conversationID || selectedMeetingSeries != nil {
            select(hit.conversationID)
        }
        let limit = searchWork.historyPageLimit
        searchWork.openTask = Task { @MainActor [weak self, engine] in
            let target = try? await engine.loadHistory(in: hit.conversationID, until: hit, pageLimit: limit)
            guard !Task.isCancelled, let self else { return }
            var state = search
            state.bar?.isOpening = false
            // The person went elsewhere while history paged: stay there.
            guard isViewingConversation(hit.conversationID) else {
                search = state
                return
            }
            // The hit is not stored: the store refused it (the engine has
            // recorded why), or lost it before the open read it back. There
            // is nothing to land on.
            guard let target else {
                state.bar?.unreachable = .tooFarBack
                search = state
                return
            }
            land(on: target)
            state.highlight = target.message.id
            state.openGeneration += 1
            search = state
        }
    }

    /// `open(conversation:message:)`'s rule, from what the engine read: a
    /// root is scrolled to; a reply opens its thread at itself, and the
    /// transcript scrolls to the thread's first message, when it is stored.
    func land(on target: HistoryTarget) {
        let message = target.message
        guard message.isReply else {
            scrollTarget = message.id
            return
        }
        scrollTarget = target.threadRoot
        openThread(message.threadID)
        threads.scrollTarget = message.id
        threads.scrollGeneration += 1
    }

    private func cancelBarPage() {
        searchWork.barPageTask?.cancel()
        searchWork.barPageTask = nil
    }

    /// Saved after any earlier save, so the newest search is the newest
    /// recent, and `stop()` cancels the chain through its one handle.
    private func recordSearch(_ text: String) {
        let previous = searchWork.recordTask
        searchWork.recordTask = Task { [engine] in
            await withTaskCancellationHandler {
                await previous?.value
            } onCancel: {
                previous?.cancel()
            }
            guard !Task.isCancelled else { return }
            await engine.recordSearch(text)
        }
    }

    private func loadBarPage(after cursor: MessageSearchCursor, thenOpen target: Int) {
        guard let query = search.bar?.query else { return }
        searchWork.barPageTask?.cancel()
        // Cleared the moment this retry asks, not when it lands.
        var state = search
        state.bar?.pageFailed = false
        search = state
        searchWork.barPageTask = Task { @MainActor [weak self, engine] in
            let page = try? await engine.searchMessages(query, after: cursor)
            guard !Task.isCancelled, let self else { return }
            guard var bar = search.bar, bar.query == query else { return }
            var state = search
            guard let page else {
                bar.pageFailed = true
                state.bar = bar
                search = state
                return
            }
            let known = Set(bar.hits.map(\.id))
            bar.hits += page.hits.filter { !known.contains($0.id) }
            bar.next = page.next
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
