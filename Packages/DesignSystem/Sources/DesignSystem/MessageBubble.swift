import ChatKit
import SwiftUI

/// One row in `MessageList`. Its own file so `MessageList.swift` stays under
/// `file_length`.
struct MessageBubble: View {
    let message: Message
    let state: ChatSceneState
    var loadAttachment: ((Attachment, AttachmentSize) async throws -> Data)?
    var openAttachment: ((Attachment) async throws -> URL)?
    var loadRemoteImage: ((URL) async throws -> Data)?
    var downloads: [String: AttachmentDownloadState] = [:]
    var attachmentFiles: AttachmentFileActions?
    var reactions: ReactionActions?
    var own: OwnMessageHandlers?
    var openThread: ((MessageThread.ID) -> Void)?
    /// The message a search opened, and whether its tint is currently shown
    /// (search spec §1.5). Not a conditional wrapper around `body` (CLAUDE.md):
    /// every bubble carries the same background, whose opacity is zero unless
    /// it is the marked one and the mark is on.
    var marked: Message.ID?
    var markOn = false

    /// Whether the full emoji picker is open for this message: from either
    /// menu's "More Emoji…" or the row's "+" (reactions spec §4.1-§4.3).
    @State private var picking = false

    /// The transcript's, which `MessageList` sets to `LinkPolicy.openURLAction`.
    @Environment(\.openURL) private var openURL

    private var parts: AttachmentLayout.Parts {
        AttachmentLayout.parts(of: message, canLoadImages: loadAttachment != nil)
    }

    private var ownItems: OwnMessageMenuItems? {
        own?.items(for: message)
    }

    private var isMine: Bool {
        message.sender == state.me
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMine {
                Spacer(minLength: 60)
            }
            if !isMine {
                Avatar(
                    member: message.sender,
                    directory: state.directory,
                    size: 26
                )
            }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                if isMine {
                    // An outgoing bubble has no sender name to sit beside, so
                    // the stamp stands alone. It is shown at all because a
                    // conversation where only one side is dated makes the
                    // other side's times unreadable as a sequence.
                    timestamp
                } else {
                    HStack(spacing: 6) {
                        Text(Display.name(of: message.sender, in: state.directory))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        timestamp
                    }
                }
                if message.isDeleted {
                    bubble
                } else {
                    // Pictures above the words, as Messages draws them, and
                    // files last; an image-only message has no empty bubble.
                    if let loadAttachment {
                        ForEach(parts.images, id: \.id) { image in
                            AttachmentImage(attachment: image, load: loadAttachment, open: openAttachment)
                        }
                    }
                    if parts.showsText {
                        bubble
                    }
                    ForEach(parts.files, id: \.id) {
                        AttachmentChip(
                            attachment: $0,
                            state: downloads[$0.id] ?? .idle,
                            actions: attachmentFiles
                        )
                    }
                    // Link cards, each with the row's menu plus Open and Copy Link
                    // (links spec §7.3, §7.5).
                    ForEach(parts.previews, id: \.url) { link in
                        LinkPreviewCard(link: link, load: loadRemoteImage)
                            .modifier(ReactionMenu(
                                message: message, actions: reactions, own: ownItems,
                                onMore: { picking = true }, link: link.url
                            ))
                    }
                    ForEach(Array(message.cards.enumerated()), id: \.offset) { _, card in
                        AppCardView(card: card, load: loadRemoteImage)
                    }
                }
                if !message.reactions.isEmpty {
                    ReactionRow(
                        reactions: message.reactions,
                        toggle: reactions.map { actions in
                            { choice, add in actions.toggle(message.id, choice, add) }
                        },
                        loadImage: reactions?.customImage,
                        onAdd: reactions == nil || message.isDeleted ? nil : { picking = true }
                    )
                }
                if let mark = ThreadMark(
                    thread: state.threads.summaries[message.threadID],
                    message: message,
                    directory: state.directory,
                    open: openThread.map { open in { open(message.threadID) } }
                ) {
                    mark
                }
            }
            .modifier(ReactionMenu(message: message, actions: reactions, own: ownItems) { picking = true })
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                if let reactions {
                    EmojiPicker(reactions: message.reactions, actions: reactions) { choice, add in
                        reactions.toggle(message.id, choice, add)
                        picking = false
                    }
                }
            }
            if !isMine {
                Spacer(minLength: 60)
            }
        }
        .padding(.vertical, 2)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.yellow.opacity(markOn && marked == message.id ? 0.25 : 0))
                .padding(.horizontal, -6)
        }
    }

    /// The date is included only once it is not today's - see
    /// `Display.timestamp(of:now:calendar:locale:)`.
    ///
    /// `now` is left at its default, so it is read afresh on every render.
    /// That means a "Yesterday" label written just before midnight stays
    /// wrong until something re-renders the row; a timer invalidating the
    /// whole list once a minute would cost more than the staleness does, and
    /// Apple's own apps behave the same way.
    private var timestamp: some View {
        Text(Display.timestamp(of: message.createdAt))
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder private var bubble: some View {
        if message.isDeleted {
            // A tombstone renders as a tombstone. It keeps its place because
            // the protocol keeps sending it and a hole would break paging.
            Text("Message deleted")
                .font(.callout.italic())
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
        } else {
            textBubble
                .background(isMine ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quinary))
                .foregroundStyle(isMine ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private var editedLabel: some View {
        Text("edited")
            .font(.caption2)
            .foregroundStyle(isMine ? .white.opacity(0.7) : .secondary)
    }

    #if os(macOS)
        /// The text view is the bubble, padding included, so a right-click
        /// anywhere on it opens the native menu with the reaction row (native
        /// text menu spec §2). With an "edited" label the label takes the
        /// bottom padding, and the bubble's size is what it was.
        private var textBubble: some View {
            VStack(alignment: .leading, spacing: 2) {
                MessageTextView(
                    text: MessageTextAttributes.attributed(
                        message.text, mentions: message.mentions, links: message.links, me: state.me,
                        inOwnBubble: isMine
                    ),
                    insets: NSEdgeInsets(
                        top: 7,
                        left: 12,
                        bottom: message.editedAt == nil ? 7 : 0,
                        right: 12
                    ),
                    message: message,
                    actions: reactions,
                    onMore: { picking = true },
                    own: ownItems,
                    inOwnBubble: isMine,
                    open: { openURL($0) }
                )
                if message.editedAt != nil {
                    editedLabel
                        .padding(.horizontal, 12)
                        .padding(.bottom, 7)
                }
            }
        }
    #else
        private var textBubble: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(MentionHighlight.attributed(
                    message.text, mentions: message.mentions, links: message.links, me: state.me,
                    inOwnBubble: isMine
                ))
                .textSelection(.enabled)
                if message.editedAt != nil {
                    editedLabel
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    #endif
}
