import ChatKit
import SwiftUI

extension MessageList {
    var hasPendingScrollTarget: Bool {
        state.isLoadingScrollTarget || state.scrollTarget.map {
            TranscriptScroll.Request(id: $0, generation: state.searchOpenGeneration) != honoured
        } ?? false
    }

    var preservesReadingPosition: Bool {
        !hasPendingScrollTarget && targetWindowBounds != [state.messages.first?.id, state.messages.last?.id]
    }

    /// The floating button: to the end of what is loaded, or through the
    /// same latest jump as the list's own button when the newest messages
    /// are not loaded.
    func jumpToLatest(_ action: TranscriptLatestJump.Action, _ proxy: ScrollViewProxy) {
        targetPlacement = nil
        targetWindowBounds = nil
        switch action {
        case .scroll:
            guard !state.messages.isEmpty else { return }
            paging.hasUserIntent = false
            readingAnchor.cancel()
            // At once: a long animated scroll through rows not yet measured
            // lands short of the end.
            follow.follow()
            proxy.scrollTo(TranscriptEndMarker.id, anchor: .bottom)
        case .load:
            guard let loadNewerMessages else { return }
            latestJumpRequested = true
            readingAnchor.cancel()
            loadNewerMessages()
        }
    }

    /// A list made for an account coming back puts the transcript where it
    /// was, and does not honour again what it honoured then. A message asked
    /// for since (a search or a mention) wins.
    func resumeIfReturning(_ proxy: ScrollViewProxy) -> Bool {
        guard !hasPlacedMessages, let saved = resume?.saved else { return false }
        if honoured == nil {
            honoured = saved.honoured
        }
        guard let id = saved.message, state.messages.contains(where: { $0.id == id }) else { return false }
        if let target = state.scrollTarget,
           TranscriptScroll.Request(id: target, generation: state.searchOpenGeneration) != honoured {
            return false
        }
        hasPlacedMessages = true
        follow.detach()
        proxy.scrollTo(id, anchor: .top)
        return true
    }

    func pageIfNeeded(_ page: TranscriptPaging.Page?) {
        switch page {
        case .older:
            guard state.hasOlderMessages, !state.isLoadingOlderMessages, !state.isLoadingNewerMessages,
                  let boundary = state.messages.first?.id, boundary != lastOlderBoundary,
                  let loadOlderMessages else { return }
            lastOlderBoundary = boundary
            readingAnchor.capture()
            loadOlderMessages()
        case .newer:
            guard !state.newerMessagesAreLatestJump,
                  state.hasNewerMessages, !state.isLoadingNewerMessages, !state.isLoadingOlderMessages,
                  let boundary = state.messages.last?.id, boundary != lastNewerBoundary,
                  let loadNewerMessages else { return }
            lastNewerBoundary = boundary
            readingAnchor.capture()
            newerPageFrom = boundary
            loadNewerMessages()
        case nil:
            break
        }
    }
}
