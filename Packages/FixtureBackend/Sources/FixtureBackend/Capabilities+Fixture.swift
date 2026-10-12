import ChatKit

public extension Capabilities {
    /// Everything on.
    ///
    /// The default for a `FakeBackend`, because the common case is "stand in
    /// for a working backend". The interesting case is the other one: pass a
    /// deliberately sparse `Capabilities` and the fake starts refusing
    /// commands, which is the only way the app's degradation paths can be
    /// exercised at all - a real bridge backend says yes to nearly everything.
    ///
    /// Written out flag by flag rather than with a "set them all" helper, so
    /// that adding a capability to ChatKit makes this a compile-time decision
    /// instead of silently opting the fake in.
    static let fixture = Capabilities(
        canSendMessages: true,
        canEditMessages: true,
        canDeleteMessages: true,
        canReact: true,
        canSendTypingState: true,
        receivesTypingState: true,
        receivesReadReceipts: true,
        canSetNotificationLevel: true,
        canSetStatus: true,
        canMarkRead: true,
        canMarkUnread: true, canHideConversations: true, canBlockConversations: true,
        canLeaveConversations: true, canDeleteConversations: true, canOpenDirectConversations: true,
        supportsThreads: true,
        needsFollowedThreadsBackfill: true,
        supportsHistoryCatchUp: true,
        canFetchAttachments: true,
        canDownloadFiles: true,
        canSendAttachments: true,
        canMention: true,
        canMentionNonMembers: true,
        needsMentionBackfill: true,
        canFetchRemoteImages: true,
        canSearchMessages: true,
        messageSearchFilters: [
            .from, .conversation, .olderThan, .newerThan, .hasFile, .hasLink, .mentionsMe, .newestFirst
        ]
    )
}
