import ChatKit

/// What the bridge can actually do - split out of `LocalBridgeBackend.swift`
/// once search's own additions pushed that file to `file_length`, the same
/// convention `+Errors.swift`, `+SelfIdentification.swift` and `+Capture.swift`
/// already established.
///
/// A computed property rather than the `nonisolated let` it used to be: the
/// value is a pure constant construction that touches no actor-isolated
/// state, so moving it out of the primary declaration costs nothing - Swift
/// only requires a type's *stored* properties to live in the primary
/// declaration, and this one never was anything but a fixed set of flags.
public extension LocalBridgeBackend {
    /// Almost nothing is advertised until it works.
    ///
    /// Not modesty - the UI reads `capabilities` to decide what to offer, and a
    /// bridge claiming it could do something it could not would hand the user a
    /// composer that silently swallowed their messages. `canSendMessages` is
    /// now true: `send(_:)` posts through `create_topic` /
    /// `create_message` (`LocalBridgeBackend+Send.swift`), `[Verify]` until a
    /// deliberate single send against live traffic confirms the shape.
    /// `supportsThreads` is the other exception: `loadConversations()` now maps
    /// `isThreaded` for real (`WorldMapping`), so a client can tell a flat
    /// group from a threaded one without guessing.
    /// `canMarkRead` is now true: `.markRead` posts through
    /// `mark_group_readstate` (`LocalBridgeBackend+ReadState.swift`) and the
    /// response's own `GroupReadState` becomes `.readStateChanged`.
    /// `[Verify]` until one deliberate call against live traffic confirms the
    /// shape. `receivesReadReceipts` maps other people's positions from history
    /// and channel events; conversation-level enabled state remains a separate gate.
    /// Typing uses the provider's group/topic context. Live delivery remains [Verify].
    /// `canDownloadFiles` is backed by `findings.md` §52.10's live download.
    /// `canReact` is true: `.setReaction` posts through `update_reaction`
    /// (`LocalBridgeBackend+Reactions.swift`), `[Verify]` until a live toggle
    /// confirms the shape.
    /// `canFetchCustomEmoji` is true on `findings.md` §54.4's capture: the
    /// image call is the one Chat on the web makes, `[Verify]` from here.
    /// `canSendAttachments` is true on both references' agreement
    /// (`LocalBridgeBackend+Uploads.swift`), `[Verify]` until a live upload.
    /// `canEditMessages` and `canDeleteMessages` are true: `edit_message` and
    /// `delete_message` (`LocalBridgeBackend+EditDelete.swift`), `[Verify]`
    /// until `--probe=edit` runs.
    ///
    /// Search applies newer-than and direct-conversation matching to each
    /// provider result page. Empty filtered pages retain their continuation.
    nonisolated var capabilities: Capabilities {
        Capabilities(
            canSendMessages: true, canEditMessages: true, canDeleteMessages: true, canReact: true,
            canSendTypingState: true, receivesTypingState: true, receivesReadReceipts: true,
            canSetStatus: true, canMarkRead: true,
            canMarkUnread: true, canHideConversations: true, canBlockConversations: true,
            canLeaveConversations: true, canDeleteConversations: true,
            canCreateConversations: true, canReadConversationDetails: true, canBrowseSpaces: true,
            canOpenDirectConversations: true,
            supportsThreads: true, needsThreadUnreadClearBeforeRead: true,
            canFetchAttachments: true, canDownloadFiles: true, canFetchCustomEmoji: true,
            canSendAttachments: true, maximumAttachmentBytes: 200 * 1024 * 1024,
            canMention: true, canMentionNonMembers: true, needsMentionBackfill: true,
            canFetchRemoteImages: true, canSearchMessages: true,
            messageSearchFilters: [
                .from, .conversation, .olderThan, .newerThan, .hasFile, .hasLink, .mentionsMe, .newestFirst
            ], internalLinkHosts: ["chat.google.com"],
            extendedFlags: ["formattedMessages", "quotedMessages", "cardActions", "forwardMessages"]
        )
    }
}
