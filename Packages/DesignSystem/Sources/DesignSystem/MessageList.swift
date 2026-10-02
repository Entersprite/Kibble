import ChatKit
import SwiftUI

/// Where the transcript scrolls (ruling 14). A scroll target, once loaded,
/// is scrolled to once, and after that the newest message is again what
/// arrivals scroll to. Pure, so each case is a test.
enum TranscriptScroll {
    /// What `onChange` watches: the newest message, the target, and whether
    /// the target has loaded. So a target that arrives after the newest
    /// still fires.
    struct Trigger: Equatable {
        let newest: Message.ID?
        let target: Message.ID?
        let targetLoaded: Bool

        init(_ state: ChatSceneState) {
            newest = state.messages.last?.id
            target = state.scrollTarget
            targetLoaded = state.scrollTarget.map { id in state.messages.contains { $0.id == id } } ?? false
        }
    }

    enum Destination: Equatable {
        case message(Message.ID)
        case newest(Message.ID)
    }

    static func destination(messages: [Message], target: Message.ID?, honoured: Message.ID?) -> Destination? {
        if let target, target != honoured, messages.contains(where: { $0.id == target }) {
            return .message(target)
        }
        return messages.last.map { .newest($0.id) }
    }
}

/// The transcript.
public struct MessageList: View {
    let state: ChatSceneState
    /// `ChatSceneActions.loadAttachment` and `.openAttachment`, handed down to
    /// each bubble. `nil` draws images as their names.
    let loadAttachment: ((Attachment, AttachmentSize) async throws -> Data)?
    let openAttachment: ((Attachment) async throws -> URL)?
    /// `ChatSceneState.downloads` and `ChatSceneActions.attachmentFiles`,
    /// handed down to each bubble's file chips the same way. `nil` actions
    /// draw a plain label (`CLAUDE.md`: never draw a control the seam cannot
    /// honour).
    let downloads: [String: AttachmentDownloadState]
    let attachmentFiles: AttachmentFileActions?

    /// The last target this list scrolled to, so that it is honoured once.
    /// `@State` is enough: opening a mention always passes through the
    /// Mentions pane, which removes this view, so a fresh list has honoured
    /// nothing.
    @State private var honoured: Message.ID?

    public init(
        state: ChatSceneState,
        loadAttachment: ((Attachment, AttachmentSize) async throws -> Data)? = nil,
        openAttachment: ((Attachment) async throws -> URL)? = nil,
        downloads: [String: AttachmentDownloadState] = [:],
        attachmentFiles: AttachmentFileActions? = nil
    ) {
        self.state = state
        self.loadAttachment = loadAttachment
        self.openAttachment = openAttachment
        self.downloads = downloads
        self.attachmentFiles = attachmentFiles
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(state.messages, id: \.id) { message in
                        MessageBubble(
                            message: message, state: state,
                            loadAttachment: loadAttachment, openAttachment: openAttachment,
                            downloads: downloads, attachmentFiles: attachmentFiles
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: TranscriptScroll.Trigger(state), initial: true) {
                switch TranscriptScroll.destination(
                    messages: state.messages, target: state.scrollTarget, honoured: honoured
                ) {
                case let .message(id)?:
                    honoured = id
                    proxy.scrollTo(id, anchor: .center)
                case let .newest(id)?:
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                case nil:
                    break
                }
            }
        }
        .overlay {
            if state.messages.isEmpty {
                ContentUnavailableView(
                    "No messages",
                    systemImage: "text.bubble",
                    description: Text("History loads when you open a conversation.")
                )
            }
        }
    }
}

struct MessageBubble: View {
    let message: Message
    let state: ChatSceneState
    var loadAttachment: ((Attachment, AttachmentSize) async throws -> Data)?
    var openAttachment: ((Attachment) async throws -> URL)?
    var downloads: [String: AttachmentDownloadState] = [:]
    var attachmentFiles: AttachmentFileActions?

    private var parts: AttachmentLayout.Parts {
        AttachmentLayout.parts(of: message, canLoadImages: loadAttachment != nil)
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
                    size: 26,
                    presence: Display.presence(
                        of: message.sender, directory: state.directory, me: state.me,
                        connection: state.connection
                    )
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
                }
                if !message.reactions.isEmpty {
                    ReactionRow(reactions: message.reactions)
                }
            }
            if !isMine {
                Spacer(minLength: 60)
            }
        }
        .padding(.vertical, 2)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(MentionHighlight.attributed(
                    message.text, mentions: message.mentions, me: state.me, inOwnBubble: isMine
                ))
                .textSelection(.enabled)
                if message.editedAt != nil {
                    Text("edited")
                        .font(.caption2)
                        .foregroundStyle(isMine ? .white.opacity(0.7) : .secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isMine ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quinary))
            .foregroundStyle(isMine ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct ReactionRow: View {
    let reactions: [Reaction]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reactions, id: \.emoji) { reaction in
                HStack(spacing: 3) {
                    Text(reaction.emoji)
                    Text("\(reaction.count)").monospacedDigit()
                }
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(reaction.includesMe ? AnyShapeStyle(.tint.opacity(0.18))
                    : AnyShapeStyle(.quinary))
                .clipShape(Capsule())
            }
        }
    }
}
