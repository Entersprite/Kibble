import ChatKit
import Foundation

@MainActor
final class MeetingTranscriptWork {
    var included: [Conversation.ID] = []
    var exhausted: Set<Conversation.ID> = []
    var visible: Set<Message.ID> = []

    func reset() {
        included = []
        exhausted = []
        visible = []
    }
}

public extension ChatSessionModel {
    var meetingSeries: MeetingSeries? {
        guard let selectedMeetingSeries else { return nil }
        return MeetingSeries.build(conversations).first { $0.id == selectedMeetingSeries }
    }

    func select(_ id: Conversation.ID) {
        if let series = MeetingSeries.build(conversations)
            .first(where: { $0.occurrences.contains { $0.id == id } }) {
            selectMeeting(series, opening: id)
        } else {
            selectSingleConversation(id)
        }
    }

    func selectMeetingSeries(_ id: MeetingSeries.ID) {
        guard let series = MeetingSeries.build(conversations).first(where: { $0.id == id }) else { return }
        selectMeeting(series, opening: series.latest.id)
    }

    func visibleMeetingMessages(_ ids: Set<Message.ID>) {
        guard selectedMeetingSeries != nil else { return }
        meetingWork.visible = ids
        markVisibleMeetingMessagesRead()
    }
}

extension ChatSessionModel {
    var hasOlderMeetingOccurrences: Bool {
        guard let series = meetingSeries, let first = meetingWork.included.first,
              let index = series.occurrences.firstIndex(where: { $0.id == first }) else { return false }
        return index > 0
    }

    func isViewingConversation(_ id: Conversation.ID) -> Bool {
        selected == id || meetingSeries?.occurrences.contains { $0.id == id } == true
    }

    private func selectMeeting(_ series: MeetingSeries, opening: Conversation.ID) {
        browser.leaveDirectory()
        guard selectedMeetingSeries != series.id || !meetingWork.included.contains(opening) else { return }
        selectSingleConversation(series.latest.id)
        historyTask?.cancel()
        resetTranscript()
        selectedMeetingSeries = series.id
        meetingWork.included = [opening]
        messages = []
        observeTranscript(in: series.latest.id, request: .latest(100))
        historyTask = Task { [weak self, engine] in
            let page = await engine.requestMoreMessages(in: opening, verifyCachedRoots: true)
            guard !Task.isCancelled, let self, selectedMeetingSeries == series.id else { return }
            if opening == selected, let page {
                latestTranscriptPageLoaded(page, in: opening)
            }
        }
    }

    func reconcileMeetingSelection() {
        guard selectedMeetingSeries != nil else { return }
        let groups = MeetingSeries.build(conversations)
        guard let series = groups
            .first(where: { group in group.occurrences.contains { $0.id == selected } }) ??
            groups.first(where: { $0.id == selectedMeetingSeries })
        else { clearSelection(); return }
        let identityChanged = selectedMeetingSeries != series.id
        selectedMeetingSeries = series.id
        let oldIncluded = meetingWork.included
        meetingWork.included = series.occurrences.map(\.id).filter { oldIncluded.contains($0) }
        let latestChanged = selected != series.latest.id
        guard identityChanged || latestChanged || oldIncluded != meetingWork.included else { return }
        let followsLatest = transcriptIncludesLatest
        if latestChanged, let previous = selected {
            let old = StagingKey(conversation: previous, thread: nil)
            let new = StagingKey(conversation: series.latest.id, thread: nil)
            let staged = composerFiles.staged[old] ?? []
            composerFiles.staged[old] = staged.filter(\.isUploading)
            composerFiles.staged[new, default: []] += staged.filter { !$0.isUploading }
        }
        if latestChanged {
            selected = series.latest.id
            for watcher in conversationWatchers {
                watcher.cancel()
            }
            conversationWatchers = []
            selectionMoved(to: series.latest.id)
        }
        if followsLatest, !meetingWork.included.contains(series.latest.id) {
            meetingWork.included.append(series.latest.id)
        }
        let included = Set(meetingWork.included)
        let retained = messages.filter { included.contains($0.conversationID) }
        let request: TranscriptWindowRequest = followsLatest
            ? retained.first.map { .tail(TranscriptCursor($0), max(100, retained.count)) } ?? .latest(100)
            : retained.last.map { .ending(TranscriptCursor($0), max(100, retained.count)) } ?? .latest(100)
        observeTranscript(in: series.latest.id, request: request)
        historyTask?.cancel()
        historyTask = Task { [engine] in
            await engine.requestMoreMessages(in: series.latest.id, verifyCachedRoots: true)
        }
    }

    func loadOlderMeetingMessages() {
        guard let series = meetingSeries, hasOlderMessages,
              !isLoadingOlderMessages, !isLoadingNewerMessages, transcriptWork.pageTask == nil else { return }
        let current = messages
        guard let boundaryID = current.first?.conversationID ?? meetingWork.included.first else { return }
        let before = current.first?.id
        let generation = transcriptWork.generation
        isLoadingOlderMessages = true
        transcriptWork.pageTask = Task { @MainActor [weak self] in
            await self?.pageOlderMeetings(
                series,
                boundary: boundaryID,
                before: before,
                current: current,
                generation: generation
            )
        }
    }

    private func pageOlderMeetings(
        _ series: MeetingSeries, boundary: Conversation.ID, before: Message.ID?, current: [Message],
        generation: Int
    ) async {
        var conversation = boundary
        var cursor = before
        while !Task.isCancelled {
            if !meetingWork.exhausted.contains(conversation) {
                let page = await engine.requestMoreMessages(
                    in: conversation,
                    before: cursor,
                    verifyCachedRoots: cursor == nil
                )
                guard !Task.isCancelled, selectedMeetingSeries == series.id,
                      transcriptWork.generation == generation else { return }
                guard let page else { finishMeetingPage(); return }
                if extendMeetingTranscript(page, in: conversation, series: series, current: current) {
                    return
                }
                guard await canCrossMeetingBoundary(
                    in: conversation,
                    current: current,
                    generation: generation
                ) else { return }
                meetingWork.exhausted.insert(conversation)
            }
            guard let index = series.occurrences.firstIndex(where: { $0.id == conversation }),
                  index > 0 else {
                finishMeetingPage()
                hasOlderMessages = false
                return
            }
            conversation = series.occurrences[index - 1].id
            cursor = nil
        }
    }

    private func canCrossMeetingBoundary(
        in conversation: Conversation.ID,
        current: [Message],
        generation: Int
    ) async -> Bool {
        guard let first = current.first, first.conversationID == conversation else { return true }
        // Empty server pages cannot verify disconnected cached search context.
        // Decode only the current boundary while probing for that older cache.
        let boundary = try? await store.transcriptWindow(
            in: conversation, request: .ending(TranscriptCursor(first), 1)
        )
        guard !Task.isCancelled, transcriptWork.generation == generation else { return false }
        if boundary?.hasOlder == true {
            finishMeetingPage()
            return false
        }
        return true
    }

    private func extendMeetingTranscript(
        _ page: [Message], in conversation: Conversation.ID, series: MeetingSeries, current: [Message]
    ) -> Bool {
        let earlier = page.filter { message in
            guard !message.isReply else { return false }
            guard let first = current.first, conversation == first.conversationID else { return true }
            return message.createdAt < first.createdAt ||
                (message.createdAt == first.createdAt && message.id.rawValue < first.id.rawValue)
        }.sorted {
            $0.createdAt == $1.createdAt ? $0.id.rawValue < $1.id.rawValue : $0.createdAt < $1.createdAt
        }
        guard let lower = earlier.first else { return false }
        if !meetingWork.included.contains(conversation) {
            meetingWork.included.insert(conversation, at: 0)
        }
        let trim = max(0, current.count + earlier.count - 500)
        let upper = current.isEmpty ? earlier.last : current[max(0, current.count - 1 - trim)]
        finishMeetingPage()
        observeTranscript(in: series.latest.id, request: upper.map {
            .between(TranscriptCursor(lower), TranscriptCursor($0), 500)
        } ?? .latest(100))
        return true
    }

    func loadNewerMeetingMessages() {
        guard let series = meetingSeries, !isLoadingOlderMessages, !isLoadingNewerMessages else { return }
        if newerMessagesAreLatestJump {
            showLatestMeeting(series)
        } else if let first = messages.first {
            let lower = messages.count >= 500 ? messages[100] : first
            observeTranscript(
                in: series.latest.id,
                request: .starting(TranscriptCursor(lower), min(500, messages.count + 100))
            )
        }
    }

    func followLatestMeetingForSend() {
        guard let series = meetingSeries, !transcriptIncludesLatest else { return }
        showLatestMeeting(series)
    }

    private func showLatestMeeting(_ series: MeetingSeries) {
        meetingWork.included = [series.latest.id]
        scrollTarget = nil
        observeTranscript(in: series.latest.id, request: .latest(100))
        historyTask?.cancel()
        historyTask = Task { [engine] in
            await engine.requestMoreMessages(in: series.latest.id, verifyCachedRoots: true)
        }
    }

    private func finishMeetingPage() {
        transcriptWork.pageTask = nil
        isLoadingOlderMessages = false
    }
}
