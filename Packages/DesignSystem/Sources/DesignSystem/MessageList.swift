import ChatKit
import SwiftUI

/// Where the transcript scrolls (ruling 14). A scroll target, once loaded,
/// is scrolled to once, and after that the newest message is again what
/// arrivals scroll to. Pure, so each case is a test.
enum TranscriptScroll {
    /// A target as it was asked for: the message, and the open that asked
    /// (`ChatSceneState.searchOpenGeneration`). The same message asked for
    /// again by a newer open is a new request, so it is honoured again.
    struct Request: Equatable {
        let id: Message.ID
        var generation = 0
    }

    /// What `onChange` watches: the newest message, the target, its
    /// generation, and whether the target has loaded. So a target that
    /// arrives after the newest still fires, and so does the same target
    /// opened again.
    struct Trigger: Equatable {
        let newest: Message.ID?
        let target: Message.ID?
        let generation: Int
        let targetLoaded: Bool

        init(_ state: ChatSceneState) {
            newest = state.messages.last?.id
            target = state.scrollTarget
            generation = state.searchOpenGeneration
            targetLoaded = state.scrollTarget.map { id in state.messages.contains { $0.id == id } } ?? false
        }

        /// The same, for the thread panel's messages.
        init(_ panel: ThreadPanelState) {
            newest = panel.messages.last?.id
            target = panel.scrollTarget
            generation = panel.scrollGeneration
            targetLoaded = panel.scrollTarget.map { id in panel.messages.contains { $0.id == id } } ?? false
        }
    }

    enum Destination: Equatable {
        case message(Message.ID)
        case newest(Message.ID)
    }

    static func destination(
        messages: [Message], target: Message.ID?, generation: Int = 0, honoured: Request?
    ) -> Destination? {
        if let target, Request(id: target, generation: generation) != honoured,
           messages.contains(where: { $0.id == target }) {
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
    @State private var honoured: TranscriptScroll.Request?

    /// The message a search opened, while its two-second tint is showing
    /// (search spec §1.5). `marked` is set once per open, so a later render
    /// of the same highlight does not restart the mark, and opening it again
    /// does.
    @State private var marked: TranscriptScroll.Request?
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
                            marked: marked?.id, markOn: markOn
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
                    messages: state.messages, target: state.scrollTarget,
                    generation: state.searchOpenGeneration, honoured: honoured
                ) {
                case let .message(id)?:
                    honoured = TranscriptScroll.Request(id: id, generation: state.searchOpenGeneration)
                    proxy.scrollTo(id, anchor: .center)
                case let .newest(id)?:
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                case nil:
                    break
                }
            }
            .task(id: TranscriptMarkTrigger(state)) {
                let request = state.highlightedMessage.map {
                    TranscriptScroll.Request(id: $0, generation: state.searchOpenGeneration)
                }
                guard TranscriptMark.shouldMark(request, in: state.messages, marked: marked) else {
                    return
                }
                let justMarked = request
                marked = justMarked
                await TranscriptMark.fade(
                    on: { withAnimation(.easeIn(duration: 0.15)) { markOn = true } },
                    sleep: { try await Task.sleep(for: .seconds(2)) },
                    isStillMarked: { marked == justMarked },
                    off: { withAnimation(.easeOut(duration: 0.6)) { markOn = false } }
                )
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

/// What `MessageList`'s mark watches: the message a search opened, the open
/// that opened it, and whether the transcript has loaded it yet. `loaded` is
/// the count rather than the message ids, so the trigger stays cheap to
/// compare and still fires once the target's page lands.
struct TranscriptMarkTrigger: Equatable {
    let target: Message.ID?
    let generation: Int
    let loaded: Int

    init(_ state: ChatSceneState) {
        target = state.highlightedMessage
        generation = state.searchOpenGeneration
        loaded = state.messages.count
    }
}
