import ChatKit
import ChatPersistence
import Foundation
import GRDB

@MainActor
final class TranscriptWork {
    var watcher: Task<Void, Never>?
    var pageTask: Task<Void, Never>?
    var generation = 0
    var serverExhausted = false
    var cachedOlder = false
    var cachedNewer = false
    var isTargeted = false
    var latestPageNewestID: Message.ID?
    /// The open chat's newest page has landed since it was selected.
    var latestPageLoaded = false
    /// The directory head known before the newest-page request began.
    var verifiedLatestHead: Date?
    /// The window being observed also reads saved, unconfirmed rows.
    var includesUnconfirmed = false
    /// Which newest-page fetch owns `isLoadingLatestMessages`.
    var latestLoad = 0
}

public extension ChatSessionModel {
    func releasePresentationCaches() {
        store.releaseDecodedTranscripts()
    }

    /// Adds an older page while retaining at most 500 rendered messages.
    func loadOlderMessages() {
        if selectedMeetingSeries != nil {
            loadOlderMeetingMessages(); return
        }
        guard let selected, hasOlderMessages, !isLoadingOlderMessages, !isLoadingNewerMessages,
              transcriptWork.pageTask == nil,
              let first = messages.first else { return }
        isLoadingOlderMessages = true
        let current = messages
        let before = first.id
        let generation = transcriptWork.generation
        transcriptWork.pageTask = Task { @MainActor [weak self, engine] in
            let page = await engine.requestMoreMessages(in: selected, before: before)
            guard !Task.isCancelled, let self, self.selected == selected,
                  transcriptWork.generation == generation else { return }
            transcriptWork.pageTask = nil
            guard let page else {
                isLoadingOlderMessages = false
                return
            }
            let older = page.filter {
                !$0
                    .isReply &&
                    ($0.createdAt < first
                        .createdAt || ($0.createdAt == first.createdAt && $0.id.rawValue < first.id.rawValue))
            }.sorted {
                $0.createdAt == $1.createdAt ? $0.id.rawValue < $1.id.rawValue : $0.createdAt < $1.createdAt
            }
            guard let lower = older.first else {
                isLoadingOlderMessages = false
                transcriptWork.serverExhausted = !transcriptWork.cachedOlder
                hasOlderMessages = transcriptWork.cachedOlder
                return
            }
            let trim = max(0, current.count + older.count - 500)
            let upper = current[max(0, current.count - 1 - trim)]
            // The oldest returned root is the verified boundary. Filling a
            // short page from arbitrary older cached search context can jump
            // across messages that have never been fetched.
            observeTranscript(
                in: selected,
                request: .between(TranscriptCursor(lower), TranscriptCursor(upper), 500)
            )
        }
    }

    /// Restores newer locally stored messages after paging into older history.
    func loadNewerMessages() {
        if selectedMeetingSeries != nil {
            loadNewerMeetingMessages(); return
        }
        guard let selected, hasNewerMessages, !isLoadingOlderMessages, !isLoadingNewerMessages,
              transcriptWork.pageTask == nil,
              let first = messages.first else { return }
        isLoadingNewerMessages = true
        if transcriptWork.isTargeted {
            refreshLatestTranscript(in: selected)
            return
        }
        let lower = messages.count >= 500 ? messages[100] : first
        observeTranscript(
            in: selected,
            request: .starting(TranscriptCursor(lower), min(500, messages.count + 100))
        )
    }
}

extension ChatSessionModel {
    func resetTranscript() {
        transcriptWork.generation += 1
        transcriptWork.watcher?.cancel()
        transcriptWork.watcher = nil
        transcriptWork.pageTask?.cancel()
        transcriptWork.pageTask = nil
        transcriptWork.serverExhausted = false
        transcriptWork.cachedOlder = false
        transcriptWork.cachedNewer = false
        transcriptWork.isTargeted = false
        transcriptWork.latestPageNewestID = nil
        transcriptWork.latestPageLoaded = false
        transcriptWork.verifiedLatestHead = nil
        hasOlderMessages = false
        hasNewerMessages = false
        newerMessagesAreLatestJump = false
        isLoadingOlderMessages = false
        isLoadingNewerMessages = false
        isLoadingLatestMessages = false
        unconfirmedMessageIDs = []
        transcriptIncludesLatest = true
    }

    /// The newest page for a chat just opened. The transcript shows the saved
    /// copy meanwhile, unconfirmed rows included, and says it is loading.
    func loadLatestPage(in id: Conversation.ID, series: MeetingSeries.ID? = nil) {
        historyTask?.cancel()
        transcriptWork.latestLoad += 1
        let load = transcriptWork.latestLoad
        let head = conversations.first { $0.id == id }?.latestMainMessageAt
        isLoadingLatestMessages = true
        historyTask = Task { [weak self, engine] in
            let page = await engine.requestMoreMessages(in: id, verifyCachedRoots: true)
            // Cleared even when canceled: reconnect catch-up replaces this
            // task with its own fetch, which shows no loading state.
            if let self, transcriptWork.latestLoad == load {
                isLoadingLatestMessages = false
            }
            guard !Task.isCancelled, let self, selectedMeetingSeries == series,
                  let shown = selected else { return }
            // A failed page leaves the saved copy up, still unconfirmed.
            guard let page else { return }
            if id == shown {
                latestTranscriptPageLoaded(page, in: id, verifying: head)
            }
            // A meeting series is observed through its latest occurrence,
            // whichever occurrence was opened.
            confirmSavedTranscript(in: shown, page: page)
        }
    }

    /// The newest page landing confirms its rows, and the window's own query
    /// then stops reading the saved copy. A page that confirmed nothing in this
    /// chat (it is empty now) would leave the saved rows up for good, so then
    /// the window is asked for confirmed rows only. Only a window opened on the
    /// saved copy switches; one the person has since paged or jumped keeps its
    /// own request.
    func confirmSavedTranscript(in conversation: Conversation.ID, page: [Message]) {
        guard transcriptWork.includesUnconfirmed, selected == conversation,
              !page.contains(where: { !$0.isReply }), !unconfirmedMessageIDs.isEmpty else { return }
        observeTranscript(
            in: conversation, request: .latest(max(100, messages.count)), includingUnconfirmed: false
        )
    }

    /// Every window falls back to the saved copy while nothing in its chat is
    /// confirmed, which is also what keeps an open chat on screen when only
    /// its own history confidence is withdrawn.
    func observeTranscript(
        in conversation: Conversation.ID, request: TranscriptWindowRequest, includingUnconfirmed: Bool = true
    ) {
        transcriptWork.watcher?.cancel()
        transcriptWork.pageTask?.cancel()
        transcriptWork.pageTask = nil
        transcriptWork.generation += 1
        let generation = transcriptWork.generation
        transcriptWork.includesUnconfirmed = includingUnconfirmed
        // Until this authoritative window arrives, a target-centered window
        // must never mark a years-old position as the latest conversation read.
        switch request {
        case .around:
            transcriptWork.isTargeted = true
            transcriptIncludesLatest = false
        case .latest, .tail:
            transcriptWork.isTargeted = selectedMeetingSeries != nil && meetingWork.included.last != selected
        default: break
        }
        let observation = transcriptObservation(
            in: conversation, request: request, includingUnconfirmed: includingUnconfirmed
        )
        transcriptWork.watcher = observe(observation) { [weak self] window in
            guard let self, selected == conversation, transcriptWork.generation == generation else { return }
            messages = window.messages
            unconfirmedMessageIDs = window.unconfirmed
            transcriptWork.cachedOlder = window.hasOlder
            // Older pages are verified against the server from the oldest row
            // shown, which must itself be confirmed first.
            let olderExists = window.hasOlder || hasOlderMeetingOccurrences ||
                (!transcriptWork.serverExhausted && !messages.isEmpty &&
                    !meetingWork.exhausted.contains(messages.first?.conversationID ?? conversation))
            hasOlderMessages = window.unconfirmed.isEmpty && olderExists
            transcriptWork.cachedNewer = window.hasNewer
            let awaitingTail = selectedMeetingSeries == nil
                ? transcriptWork.isTargeted && !targetContainsConfirmedTail
                : meetingWork.included.last != selected
            hasNewerMessages = window.hasNewer || awaitingTail
            newerMessagesAreLatestJump = transcriptWork.isTargeted && hasNewerMessages
            transcriptIncludesLatest = !window.hasNewer && !awaitingTail
            if transcriptWork.pageTask == nil {
                isLoadingOlderMessages = false
                isLoadingNewerMessages = false
            }
            // Once the window reaches the tail, keep observing newest messages
            // so incoming events and optimistic sends remain visible.
            if transcriptIncludesLatest, transcriptWork.pageTask == nil, let first = messages.first {
                switch request {
                case .latest, .tail: break
                default:
                    observeTranscript(
                        in: conversation,
                        request: .tail(TranscriptCursor(first), max(100, messages.count))
                    )
                }
            }
            markSelectedReadIfNeeded()
        }
    }
}

extension ChatSessionModel {
    private func transcriptObservation(
        in conversation: Conversation.ID, request: TranscriptWindowRequest, includingUnconfirmed: Bool
    ) -> AsyncValueObservation<TranscriptWindow> {
        selectedMeetingSeries == nil
            ? store.observeTranscriptWindow(
                in: conversation, request: request, includingUnconfirmed: includingUnconfirmed
            )
            : store.observeMeetingTranscript(
                occurrences: meetingWork.included, request: request,
                includingUnconfirmed: includingUnconfirmed
            )
    }

    private var targetContainsConfirmedTail: Bool {
        guard let newest = transcriptWork.latestPageNewestID else { return false }
        return messages.contains { $0.id == newest }
    }

    func latestTranscriptPageLoaded(
        _ page: [Message],
        in conversation: Conversation.ID,
        verifying head: Date?
    ) {
        guard selected == conversation else { return }
        transcriptWork.latestPageLoaded = true
        transcriptWork.verifiedLatestHead = head
        transcriptWork.latestPageNewestID = page.filter { !$0.isReply }.max {
            $0.createdAt == $1.createdAt ? $0.id.rawValue < $1.id.rawValue : $0.createdAt < $1.createdAt
        }?.id
        if transcriptWork.isTargeted {
            let awaitingTail = !targetContainsConfirmedTail
            hasNewerMessages = transcriptWork.cachedNewer || awaitingTail
            newerMessagesAreLatestJump = hasNewerMessages
            transcriptIncludesLatest = !transcriptWork.cachedNewer && !awaitingTail
            if transcriptIncludesLatest, transcriptWork.pageTask == nil, let first = messages.first {
                observeTranscript(
                    in: conversation,
                    request: .tail(TranscriptCursor(first), max(100, messages.count))
                )
            }
        }
        markSelectedReadIfHeadIsHidden()
    }

    func refreshLatestTranscript(in conversation: Conversation.ID) {
        historyTask?.cancel()
        let generation = transcriptWork.generation
        let head = conversations.first { $0.id == conversation }?.latestMainMessageAt
        transcriptWork.pageTask = Task { @MainActor [weak self, engine] in
            let page = await engine.requestMoreMessages(in: conversation, verifyCachedRoots: true)
            guard !Task.isCancelled, let self, selected == conversation,
                  transcriptWork.generation == generation else { return }
            transcriptWork.pageTask = nil
            guard let page, page.contains(where: { !$0.isReply }) else {
                isLoadingNewerMessages = false
                return
            }
            latestTranscriptPageLoaded(page, in: conversation, verifying: head)
            scrollTarget = nil
            observeTranscript(in: conversation, request: .latest(100))
        }
    }
}
