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
        let loadingNewer: Bool
        let latestJump: Bool

        init(_ state: ChatSceneState) {
            newest = state.messages.last?.id
            target = state.scrollTarget
            generation = state.searchOpenGeneration
            targetLoaded = state.scrollTarget.map { id in state.messages.contains { $0.id == id } } ?? false
            loadingNewer = state.isLoadingNewerMessages
            latestJump = state.newerMessagesAreLatestJump
        }

        /// The same, for the thread panel's messages.
        init(_ panel: ThreadPanelState) {
            newest = panel.messages.last?.id
            target = panel.scrollTarget
            generation = panel.scrollGeneration
            targetLoaded = panel.scrollTarget.map { id in panel.messages.contains { $0.id == id } } ?? false
            loadingNewer = false
            latestJump = false
        }
    }

    enum Destination: Equatable {
        case message(Message.ID)
        case newest(Message.ID)
    }

    static func destination(
        messages: [Message], target: Message.ID?, generation: Int = 0, honoured: Request?,
        followNewest: Bool = true
    ) -> Destination? {
        if let target, Request(id: target, generation: generation) != honoured,
           messages.contains(where: { $0.id == target }) {
            return .message(target)
        }
        return followNewest ? messages.last.map { .newest($0.id) } : nil
    }
}

/// The transcript.
public struct MessageList: View {
    let checkMessageDelivery: ((Message.ID) -> Void)?
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
    let loadOlderMessages: (() -> Void)?
    let loadNewerMessages: (() -> Void)?
    var visibleMeetingMessages: ((Set<Message.ID>) -> Void)?
    /// Reply in Thread, Mark as Unread, Edit… and Delete…; `nil` offers none
    /// (edit spec §5, threads spec §5). Set by `ChatWindow` through
    /// `ownMessages(_:)`: the handlers are the window's, and internal.
    private var own: OwnMessageHandlers?

    /// The last target this list scrolled to, so that it is honoured once.
    /// `@State` is enough: opening a mention always passes through the
    /// Mentions pane, which removes this view, so a fresh list has honoured
    /// nothing.
    @State private var honoured: TranscriptScroll.Request?
    @State private var hasPlacedMessages = false
    @State private var readingAnchor = TranscriptReadingAnchor()
    @State private var nearBottom = true
    @State private var paging = TranscriptPaging()
    @State private var lastOlderBoundary: Message.ID?
    @State private var lastNewerBoundary: Message.ID?
    @State private var latestJumpRequested = false

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
        threads: ThreadActions? = nil,
        loadOlderMessages: (() -> Void)? = nil,
        loadNewerMessages: (() -> Void)? = nil,
        checkMessageDelivery: ((Message.ID) -> Void)? = nil
    ) {
        self.state = state
        self.loadAttachment = loadAttachment
        self.openAttachment = openAttachment
        self.loadRemoteImage = loadRemoteImage
        self.downloads = downloads
        self.attachmentFiles = attachmentFiles
        self.reactions = reactions
        self.threads = threads
        self.loadOlderMessages = loadOlderMessages
        self.loadNewerMessages = loadNewerMessages
        self.checkMessageDelivery = checkMessageDelivery
    }

    func ownMessages(_ handlers: OwnMessageHandlers?) -> MessageList {
        var list = self
        list.own = handlers
        return list
    }

    func meetingVisibility(_ action: ((Set<Message.ID>) -> Void)?) -> MessageList {
        var list = self
        list.visibleMeetingMessages = state.selectedMeetingSeries == nil ? nil : action
        return list
    }

    public var body: some View {
        let marker = ActivityPresentation.marker(state)
        let dividers = MeetingTranscriptPresentation.dividers(
            messages: state.messages, occurrences: state.meetingSeries?.occurrences ?? []
        )
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if state.hasOlderMessages, let loadOlderMessages {
                        Button("Load older messages") {
                            readingAnchor.capture()
                            loadOlderMessages()
                        }
                        .disabled(state.isLoadingOlderMessages || state.isLoadingNewerMessages)
                        .frame(maxWidth: .infinity)
                    }
                    ForEach(state.messages, id: \.id) { message in
                        if let start = dividers[message.id] {
                            MeetingOccurrenceDivider(start: start)
                        }
                        MessageBubble(
                            message: message,
                            state: MessageRowState(
                                message: message, scene: state, showsThread: threads != nil,
                                downloads: downloads
                            ),
                            receiptDirectory: marker?.messageID == message.id
                                ? RowDirectory.avatars(marker?.readers ?? [], in: state.directory) : [:],
                            receiptReaders: marker?.messageID == message.id ? marker?.readers ?? [] : [],
                            receiptSlot: state.capabilities.receivesReadReceipts,
                            groupReceipt: state.selectedConversation?.kind != .directMessage,
                            loadAttachment: loadAttachment, openAttachment: openAttachment,
                            loadRemoteImage: loadRemoteImage,
                            attachmentFiles: attachmentFiles,
                            reactions: reactions, own: own, openThread: threads?.open,
                            marked: marked?.id, markOn: markOn, checkDelivery: checkMessageDelivery
                        )
                        .id(message.id)
                        .modifier(TranscriptAnchorTracking(id: message.id, anchor: readingAnchor))
                        .modifier(TranscriptEndTracking(
                            isLast: message.id == state.messages.last?.id, nearBottom: $nearBottom
                        ))
                    }
                    if state.hasNewerMessages, let loadNewerMessages {
                        Button(state.newerMessagesAreLatestJump ? "Jump to latest" : "Load newer messages") {
                            latestJumpRequested = state.newerMessagesAreLatestJump
                            if latestJumpRequested {
                                readingAnchor.cancel()
                            } else {
                                readingAnchor.capture()
                            }
                            loadNewerMessages()
                        }
                        .disabled(state.isLoadingOlderMessages || state.isLoadingNewerMessages)
                        .frame(maxWidth: .infinity)
                    }
                }
                .scrollTargetLayout()
                #if os(macOS)
                    .background { TranscriptScrollBridge(anchor: readingAnchor) }
                #endif
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    // Every link under the transcript opens through one rule (links spec §7.1).
                    .environment(\.openURL, LinkPolicy.openURLAction)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if state.capabilities.receivesTypingState {
                    HStack {
                        let typists = ActivityPresentation.typists(state)
                        if !typists.isEmpty {
                            TypingIndicator(
                                members: typists,
                                directory: state.directory,
                                namesVisible: state.selectedConversation?.kind != .directMessage
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading)
                    .padding(.leading, 50).padding(.trailing, 16)
                }
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating {
                    paging.hasUserIntent = true
                }
                if phase == .interacting {
                    readingAnchor.cancel()
                }
            }
            .onScrollGeometryChange(for: CGSize.self) { $0.containerSize } action: { _, _ in
                paging.hasUserIntent = false
            }
            .onScrollTargetVisibilityChange(idType: Message.ID.self, threshold: 0.01) { ids in
                visibleMeetingMessages?(Set(ids))
                pageIfNeeded(paging.update(visibleIDs: ids, messages: state.messages))
            }
            .onChange(of: state.messages.first?.id) { previous, current in
                paging.hasUserIntent = false
                if !latestJumpRequested, hasPlacedMessages, previous != nil, current != nil {
                    _ = readingAnchor.restore(in: state.messages)
                }
            }
            .task(id: state.messages.first?.id) {
                guard let id = readingAnchor.restoringID else { return }
                await Task.yield()
                guard !Task.isCancelled, readingAnchor.restoringID == id else { return }
                readingAnchor.beginCorrection()
                proxy.scrollTo(id, anchor: .top)
            }
            .onChange(of: state.isLoadingOlderMessages) { _, loading in
                if !loading {
                    lastOlderBoundary = nil
                    readingAnchor.discardUnusedCapture()
                }
            }
            .onChange(of: state.isLoadingNewerMessages) { _, loading in
                if !loading {
                    lastNewerBoundary = nil
                    readingAnchor.discardUnusedCapture()
                    if state.newerMessagesAreLatestJump {
                        latestJumpRequested = false
                    }
                }
            }
            .onChange(of: TranscriptScroll.Trigger(state), initial: true) {
                let jumpFinished = latestJumpRequested && !state.isLoadingNewerMessages
                    && !state.newerMessagesAreLatestJump && !state.hasNewerMessages
                if jumpFinished {
                    readingAnchor.cancel()
                    hasPlacedMessages = false
                }
                switch TranscriptScroll.destination(
                    messages: state.messages, target: state.scrollTarget,
                    generation: state.searchOpenGeneration, honoured: honoured,
                    followNewest: !hasPlacedMessages || (
                        nearBottom && !state.hasNewerMessages && readingAnchor.restoringID == nil
                    )
                ) {
                case let .message(id)?:
                    paging.hasUserIntent = false
                    nearBottom = false
                    readingAnchor.cancel()
                    latestJumpRequested = false
                    honoured = TranscriptScroll.Request(id: id, generation: state.searchOpenGeneration)
                    hasPlacedMessages = true
                    proxy.scrollTo(id, anchor: .center)
                case let .newest(id)?:
                    paging.hasUserIntent = false
                    latestJumpRequested = false
                    // The first delivery is placed immediately; later arrivals
                    // follow only while the person is reading the latest edge.
                    if hasPlacedMessages {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                    } else {
                        proxy.scrollTo(id, anchor: .bottom)
                        hasPlacedMessages = true
                    }
                case nil:
                    break
                }
            }
            .onDisappear {
                paging.hasUserIntent = false
                readingAnchor.cancel()
                latestJumpRequested = false
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

    private func pageIfNeeded(_ page: TranscriptPaging.Page?) {
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
            loadNewerMessages()
        case nil:
            break
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
