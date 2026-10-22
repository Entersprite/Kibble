import ChatKit
import SwiftUI

/// One row in `MessageList`. Its own file so `MessageList.swift` stays under
/// `file_length`.
struct MessageBubble: View {
    let message: Message
    let state: MessageRowState
    var receiptDirectory: [Member.ID: Member] = [:]
    var receiptReaders: [Member.ID] = []
    var receiptSlot = false
    var groupReceipt = false
    var loadAttachment: ((Attachment, AttachmentSize) async throws -> Data)?
    var openAttachment: ((Attachment) async throws -> URL)?
    var loadRemoteImage: ((URL) async throws -> Data)?
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
    var checkDelivery: ((Message.ID) -> Void)?
    /// The row continues the previous message's group
    /// (`TranscriptGrouping`): no name or time of its own.
    var continuesGroup = false
    /// The row ends its group, so the sender's picture goes beside it, at
    /// the foot of the message, as in Messages; other rows keep the column.
    var endsGroup = true
    /// A day separator above names the day, so the row's time omits it.
    var datedBySeparator = false

    /// Whether the full emoji picker is open for this message: from either
    /// menu's "More Emoji…" (reactions spec §4.2-§4.3). The context menus are
    /// the only way to add a reaction (owner decision).
    @State private var picking = false
    /// The message's pictures and downloads as Quick Look pages.
    @State private var gallery = AttachmentGallery()

    /// The transcript's, which `MessageList` sets to `LinkPolicy.openURLAction`.
    @Environment(\.openURL) private var openURL
    @Environment(\.invokeCardAction) private var invokeCardAction

    private var parts: AttachmentLayout.Parts {
        AttachmentLayout.parts(of: message, canLoadImages: loadAttachment != nil)
    }

    private var ownItems: OwnMessageMenuItems? {
        state.canUseProviderActions ? own?.items(for: message) : nil
    }

    private var availableReactions: ReactionActions? {
        state.canUseProviderActions ? reactions : nil
    }

    private var isMine: Bool {
        message.sender == state.me
    }

    private var menu: MessageMenuContext {
        MessageMenuContext(message: message, reactions: availableReactions, own: ownItems) { picking = true }
    }

    private var addsReactions: Bool {
        availableReactions != nil && !message.isDeleted
    }

    var body: some View {
        // On the message's own foot, never the column's: the reactions,
        // delivery label, receipts and thread mark under it do not move the
        // picture.
        HStack(alignment: .messageBottom, spacing: MessageBubbleLayout.spacing) {
            if isMine {
                Spacer(minLength: MessageBubbleLayout.opposite)
            }
            if !isMine {
                avatar
            }
            column
                .modifier(ReactionMenu(context: menu))
                .popover(isPresented: $picking, arrowEdge: .bottom) {
                    if let reactions = availableReactions {
                        EmojiPicker(reactions: message.reactions, actions: reactions) { choice, add in
                            reactions.toggle(message.id, choice, add)
                            picking = false
                        }
                    }
                }
            if !isMine {
                Spacer(minLength: MessageBubbleLayout.opposite)
            }
        }
        .padding(.vertical, 2)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(SearchHighlight.color.opacity(markOn && marked == message.id ? 0.35 : 0))
                .padding(.horizontal, -6)
        }
        .padding(.top, continuesGroup ? 0 : 6)
        .quickLookPreview($gallery.selection, in: gallery.items)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .messageAccessibilityActions(menu.table(), addReaction: addsReactions ? { picking = true } : nil)
    }

    /// The sender's picture beside the group's last message; every other row
    /// keeps the picture's column empty, so the group's bubbles line up.
    @ViewBuilder private var avatar: some View {
        if endsGroup {
            Avatar(
                member: message.sender, directory: state.directory, size: MessageBubbleLayout.avatarSide,
                presence: state.senderPresence
            )
            .alignmentGuide(.messageBottom) { $0[.bottom] }
        } else {
            Color.clear.frame(width: MessageBubbleLayout.avatarSide, height: 1)
        }
    }

    private var column: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
            if !continuesGroup {
                header.accessibilityHidden(true)
            }
            // The message itself, apart from its name and the marks under
            // it: the reactions hang from its corner, and the picture lines up
            // with its foot.
            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                if message.isDeleted {
                    bubble
                } else if let status = message.callStatus {
                    CallMessageCard(status: status)
                } else {
                    messageContent
                }
            }
            .overlay(alignment: isMine ? .topLeading : .topTrailing) { tapbacks }
            .alignmentGuide(.messageBottom) { $0[.bottom] }
            // Room for the reactions above the message, so they never cover
            // the message before it.
            .padding(.top, message.reactions.isEmpty || message.isDeleted ? 0 : ReactionTapbacks.rise)
            if let delivery = state.deliveryStatus {
                MessageDeliveryLabel(
                    status: delivery,
                    checking: state.checkingDelivery,
                    check: checkDelivery.map { action in { action(message.id) } }
                )
            }
            if receiptSlot, isMine, !message.isDeleted, !message.isReply {
                HStack {
                    Spacer(minLength: 0)
                    if !receiptReaders.isEmpty {
                        ReadReceiptLabel(
                            readers: receiptReaders,
                            directory: receiptDirectory,
                            group: groupReceipt
                        )
                    }
                }
                .frame(height: 14)
            }
            if let mark = ThreadMark(
                thread: state.thread,
                message: message,
                directory: state.directory,
                open: openThread.map { open in { open(message.threadID) } }
            ) {
                mark
            }
        }
    }

    @ViewBuilder private var header: some View {
        if isMine {
            // An outgoing bubble has no sender name to sit beside, so the
            // stamp stands alone. It is shown at all because a conversation
            // where only one side is dated makes the other side's times
            // unreadable as a sequence.
            timestamp
        } else {
            HStack(spacing: 6) {
                Text(Display.name(of: message.sender, in: state.directory))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                timestamp
            }
        }
    }

    @ViewBuilder private var messageContent: some View {
        if let forwarded = message.forwardedSnapshot {
            ForwardedMessageCard(
                forwarded: forwarded, directory: state.directory, me: state.me,
                downloads: state.downloads, loadAttachment: loadAttachment,
                openAttachment: openAttachment, loadRemoteImage: loadRemoteImage,
                attachmentFiles: attachmentFiles, menu: menu, gallery: gallery,
                quickLook: quickLook
            )
        }
        if let quote = message.content?.quote {
            MessageQuotePreview(quote: quote, directory: state.directory)
        }
        // Pictures above the words, as Messages draws them, and files last;
        // an image-only message has no empty bubble.
        if let loadAttachment {
            ForEach(parts.images, id: \.id) { image in
                AttachmentImage(
                    attachment: image, load: loadAttachment, open: openAttachment, gallery: gallery,
                    quickLook: openAttachment == nil ? nil : quickLook, menu: menu,
                    saveAs: attachmentFiles?.saveAs
                )
            }
        }
        if parts.showsText {
            bubble
        }
        ForEach(parts.files, id: \.id) {
            AttachmentChip(
                attachment: $0,
                state: state.downloads[$0.id] ?? .idle,
                actions: attachmentFiles,
                menu: menu,
                quickLook: quickLook
            )
        }
        // Link cards, each with the row's menu plus Open Link, Copy Link and
        // Share (links spec §7.3, §7.5).
        ForEach(parts.previews, id: \.url) { link in
            LinkPreviewCard(link: link, load: loadRemoteImage)
                .modifier(ReactionMenu(context: menu, link: link.url))
        }
        ForEach(Array(message.cards.enumerated()), id: \.offset) { _, card in
            AppCardView(card: card, load: loadRemoteImage, perform: performCardAction)
        }
    }

    /// A card's action, addressed to this message; `nil` without a handler.
    private var performCardAction: (@MainActor (AppCardAction) async throws -> AppCardActionResult)? {
        guard let invoke = invokeCardAction else { return nil }
        let message = message
        return { action in
            try await invoke(AppCardActionRequest(
                conversation: message.conversationID,
                thread: message.threadID,
                message: message.id,
                action: action
            ))
        }
    }

    /// Opens Quick Look at `target`, with every picture and finished
    /// download of the message as pages, the forwarded snapshot's included,
    /// in the order they are drawn. Worked out when asked, never while drawn.
    private var quickLook: (Attachment) -> Void {
        let forwarded = message.forwardedSnapshot.map {
            AttachmentLayout.parts(of: $0.message, canLoadImages: loadAttachment != nil)
        }
        let pictures = (forwarded?.images ?? []) + parts.images
        let downloads = state.downloads
        let documents = ((forwarded?.files ?? []) + parts.files).filter { downloads[$0.id] == .done }
        return { [gallery, openAttachment, attachmentFiles] target in
            gallery.open(
                target, pictures: pictures, documents: documents, resolve: openAttachment,
                placed: attachmentFiles?.finishedFile
            )
        }
    }

    /// The date is included only once it is not today's - see
    /// `Display.timestamp(of:now:calendar:locale:)` - unless a separator
    /// above already names the day.
    ///
    /// `now` is left at its default, so it is read afresh on every render.
    /// That means a "Yesterday" label written just before midnight stays
    /// wrong until something re-renders the row; a timer invalidating the
    /// whole list once a minute would cost more than the staleness does, and
    /// Apple's own apps behave the same way.
    private var timestamp: some View {
        Text(datedBySeparator
            ? TranscriptDayLabel.time(of: message.createdAt)
            : Display.timestamp(of: message.createdAt))
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
            BubbleWidthLimit(reserve: MessageBubbleLayout.reserve(isMine: isMine)) {
                textBubble
                    .background(isMine ? AnyShapeStyle(MessageBubbleLayout.ownFill) : AnyShapeStyle(.quinary))
                    .foregroundStyle(isMine ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
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
                    insets: NSEdgeInsets(
                        top: 7,
                        left: 12,
                        bottom: message.editedAt == nil ? 7 : 0,
                        right: 12
                    ),
                    message: message,
                    actions: availableReactions,
                    me: state.me,
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

extension MessageBubble {
    /// Hung from the message's top corner: its foot over the message's top
    /// edge, a little of it over the corner, the rest past the message's
    /// edge. Always in the overlay, drawing nothing without reactions, so
    /// these guides hold (`ReactionTapbacks.body`).
    var tapbacks: some View {
        let mine = isMine
        return ReactionTapbacks(
            reactions: message.isDeleted ? [] : message.reactions,
            isMine: mine,
            toggle: availableReactions.map { actions in
                { choice, add in actions.toggle(message.id, choice, add) }
            },
            loadImage: availableReactions?.customImage
        )
        .alignmentGuide(.top) { $0[.bottom] - ReactionTapbacks.overlap }
        .alignmentGuide(mine ? HorizontalAlignment.leading : .trailing) { dimensions in
            let inset = ReactionTapbacks.inset
            return mine ? dimensions[.trailing] - inset : dimensions[.leading] + inset
        }
    }

    /// "Alex Lee, 3:25 PM": the row's sender and time, which a continuing
    /// row does not draw. The header is hidden from VoiceOver, so every row
    /// says the same thing.
    private var accessibilityLabel: String {
        let sender = isMine ? "You" : Display.name(of: message.sender, in: state.directory)
        return "\(sender), \(Display.timestamp(of: message.createdAt))"
    }
}
