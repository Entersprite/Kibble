import ChatKit
import Foundation

extension ChatSessionModel {
    /// Only a head captured before a successful newest-page request may
    /// extend an automatic read beyond messages actually shown.
    func newestTranscriptPosition(in conversation: Conversation.ID) -> Date? {
        let shown = messages.filter { !$0.id.rawValue.hasPrefix("local/") }.map(\.createdAt).max()
        guard transcriptWork.latestPageLoaded,
              let head = transcriptWork.verifiedLatestHead else { return shown }
        return shown.map { max($0, head) } ?? head
    }

    /// Called only after the automatic-read guards admit this active chat.
    /// Keep the last proof while another head is checked. Loading suppresses
    /// duplicate requests; failure or cancellation clears loading, so a later
    /// external trigger can retry without a failure rearming itself.
    func verifyHiddenTranscriptHeadIfNeeded(in conversation: Conversation.ID) {
        guard !isLoadingLatestMessages,
              let head = conversations.first(where: { $0.id == conversation })?.latestMainMessageAt,
              head > (transcriptWork.verifiedLatestHead ?? .distantPast) else { return }
        let shown = messages.filter { !$0.id.rawValue.hasPrefix("local/") }.map(\.createdAt).max()
        guard head > (shown ?? .distantPast) else { return }
        loadLatestPage(in: conversation)
    }

    /// A directory head may advance without changing any transcript row.
    /// Re-enter the ordinary guarded trigger to verify or mark that head.
    func markSelectedReadIfHeadIsHidden() {
        guard let selected, selectedMeetingSeries == nil, transcriptIncludesLatest else { return }
        let shown = messages.filter { !$0.id.rawValue.hasPrefix("local/") }.map(\.createdAt).max()
        let head = conversations.first(where: { $0.id == selected })?.latestMainMessageAt
        guard (head ?? .distantPast) > (shown ?? .distantPast)
            || newestTranscriptPosition(in: selected) != shown else { return }
        markSelectedReadIfNeeded()
    }
}
