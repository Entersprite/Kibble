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

        /// The same, for the thread panel's messages.
        init(_ panel: ThreadPanelState) {
            newest = panel.messages.last?.id
            target = panel.scrollTarget
            targetLoaded = panel.scrollTarget.map { id in panel.messages.contains { $0.id == id } } ?? false
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
    /// `ChatSceneActions.loadRemoteImage`, for link and app cards.
    let loadRemoteImage: ((URL) async throws -> Data)?
    /// `ChatSceneState.downloads` and `ChatSceneActions.attachmentFiles`,
    /// handed down to each bubble's file chips the same way. `nil` actions
    /// draw a plain label (`CLAUDE.md`: never draw a control the seam cannot
    /// honour).
    let downloads: [String: AttachmentDownloadState]
    let attachmentFiles: AttachmentFileActions?
    /// `ChatSceneActions.reactions`, handed down to each bubble. `nil` draws
    /// a read-only row and no context menu (`CLAUDE.md`: never draw a
    /// control the seam cannot honour).
    let reactions: ReactionActions?
    /// The thread actions where the conversation has replies
    /// (`ChatWindow.offeredThreadActions`): a bubble's mark opens its thread;
    /// `nil` draws no mark.
    let threads: ThreadActions?
    /// Reply in Thread, Mark as Unread, Edit… and Delete…; `nil` offers none
    /// (edit spec §5, threads spec §5). Set by `ChatWindow` through
    /// `ownMessages(_:)`: the handlers are the window's, and internal.
    private var own: OwnMessageHandlers?

    /// The last target this list scrolled to, so that it is honoured once.
    /// `@State` is enough: opening a mention always passes through the
    /// Mentions pane, which removes this view, so a fresh list has honoured
    /// nothing.
    @State private var honoured: Message.ID?

    /// The message a search opened, while its two-second tint is showing
    /// (search spec §1.5). `marked` is set once, so a later render of the
    /// same highlight does not restart the mark.
    @State private var marked: Message.ID?
    @State private var markOn = false

    public init(
        state: ChatSceneState,
        loadAttachment: ((Attachment, AttachmentSize) async throws -> Data)? = nil,
        openAttachment: ((Attachment) async throws -> URL)? = nil,
        loadRemoteImage: ((URL) async throws -> Data)? = nil,
        downloads: [String: AttachmentDownloadState] = [:],
        attachmentFiles: AttachmentFileActions? = nil,
        reactions: ReactionActions? = nil,
        threads: ThreadActions? = nil
    ) {
        self.state = state
        self.loadAttachment = loadAttachment
        self.openAttachment = openAttachment
        self.loadRemoteImage = loadRemoteImage
        self.downloads = downloads
        self.attachmentFiles = attachmentFiles
        self.reactions = reactions
        self.threads = threads
    }

    func ownMessages(_ handlers: OwnMessageHandlers?) -> MessageList {
        var list = self
        list.own = handlers
        return list
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(state.messages, id: \.id) { message in
                        MessageBubble(
                            message: message, state: state,
                            loadAttachment: loadAttachment, openAttachment: openAttachment,
                            loadRemoteImage: loadRemoteImage,
                            downloads: downloads, attachmentFiles: attachmentFiles,
                            reactions: reactions, own: own, openThread: threads?.open,
                            marked: marked, markOn: markOn
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                // Every link under the transcript opens through one rule (links spec §7.1).
                .environment(\.openURL, LinkPolicy.openURLAction)
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
            .task(id: TranscriptMarkTrigger(target: state.highlightedMessage, loaded: state.messages.count)) {
                guard TranscriptMark.shouldMark(state.highlightedMessage, in: state.messages, marked: marked)
                else {
                    return
                }
                marked = state.highlightedMessage
                withAnimation(.easeIn(duration: 0.15)) { markOn = true }
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.easeOut(duration: 0.6)) { markOn = false }
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

/// What `MessageList`'s mark watches: the message a search opened, and
/// whether the transcript has loaded it yet. `loaded` is the count rather
/// than the message ids, so the trigger stays cheap to compare and still
/// fires once the target's page lands.
private struct TranscriptMarkTrigger: Equatable {
    let target: Message.ID?
    let loaded: Int
}
