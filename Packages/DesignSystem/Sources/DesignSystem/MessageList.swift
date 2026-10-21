import ChatKit
import SwiftUI

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
    var own: OwnMessageHandlers?
    /// Where this account's transcript was when it last left the screen.
    private var resume: TranscriptResume?

    /// The last target this list scrolled to, so that it is honoured once.
    /// `@State` is enough: opening a mention always passes through the
    /// Mentions pane, which removes this view, so a fresh list has honoured
    /// nothing.
    @State private var honoured: TranscriptScroll.Request?
    @State var hasPlacedMessages = false
    @State var readingAnchor = TranscriptReadingAnchor()
    @State var nearBottom = true
    @State var paging = TranscriptPaging()
    @State private var lastOlderBoundary: Message.ID?
    @State private var lastNewerBoundary: Message.ID?
    @State var latestJumpRequested = false
    /// The messages on screen, kept unobserved: read only when leaving.
    @State private var seen = TranscriptSeen()
    /// The newest message as of the latest render, kept unobserved: read by
    /// the newest row when it leaves (`TranscriptEndTracking`).
    @State private var newest = TranscriptNewest()
    /// Someone else's message arrived while the newest end was out of view,
    /// so the jump button says New Messages until the end is seen again.
    @State var unseenArrivals = false
    /// The newest message when a page of newer history was asked for: its
    /// arrival is history, not a new message (`noteArrival`).
    @State var newerPageFrom: Message.ID?

    /// The message a search opened, while its two-second tint is showing
    /// (search spec §1.5). `marked` is set once per open, so a later render
    /// of the same highlight does not restart the mark, and opening it again
    /// does.
    @State var marked: TranscriptScroll.Request?
    @State var markOn = false

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

    func resuming(_ resume: TranscriptResume?) -> MessageList {
        var list = self
        list.resume = resume
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
        let placements = TranscriptGrouping.placements(messages: state.messages, dividers: dividers)
        let newestID = newest.track(state.messages)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    // Older messages load as the person scrolls up to them
                    // (`pageOlderNearTheTop`), with no button to press. The
                    // slot is there while there are any, the spinner only
                    // while a page loads, so nothing below moves when it does.
                    if state.hasOlderMessages {
                        ProgressView()
                            .controlSize(.small)
                            .opacity(state.isLoadingOlderMessages ? 1 : 0)
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .accessibilityHidden(!state.isLoadingOlderMessages)
                    }
                    ForEach(state.messages, id: \.id) { message in
                        let placement = placements[message.id] ?? TranscriptRowPlacement()
                        // One view per message, its divider and day separator
                        // inside it: a message that sometimes brought an extra
                        // view before it threw off the lazy stack's estimates,
                        // so a jump to a message (a search, a mention) landed
                        // hundreds of rows away (measured offline).
                        VStack(alignment: .leading, spacing: 2) {
                            if let start = dividers[message.id] {
                                MeetingOccurrenceDivider(start: start)
                            }
                            if let day = placement.day {
                                TranscriptDaySeparator(day: day)
                            }
                            bubble(message, placement: placement, marker: marker)
                        }
                        .id(message.id)
                        .modifier(TranscriptAnchorTracking(id: message.id, anchor: readingAnchor))
                        .modifier(TranscriptEndTracking(
                            id: message.id, drawnNewest: newestID, newest: newest, nearBottom: $nearBottom
                        ) { followGrowth(proxy) })
                    }
                    if state.hasNewerMessages, let loadNewerMessages {
                        Button(state.newerMessagesAreLatestJump ? "Jump to Newest" : "Load Newer Messages") {
                            latestJumpRequested = state.newerMessagesAreLatestJump
                            if latestJumpRequested {
                                readingAnchor.cancel()
                            } else {
                                readingAnchor.capture()
                            }
                            newerPageFrom = state.messages.last?.id
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
                    .padding(.horizontal, TranscriptLayout.horizontalPadding)
                    .padding(.vertical, 12)
                    // Every link under the transcript opens through one rule (links spec §7.1).
                    .environment(\.openURL, LinkPolicy.openURLAction)
            }
            .modifier(TranscriptJumpOverlay(
                nearBottom: $nearBottom,
                unseen: $unseenArrivals,
                context: TranscriptLatestJump.Context(state, canLoadNewer: loadNewerMessages != nil)
            ) { jumpToLatest($0, proxy) })
            .safeAreaInset(edge: .bottom, spacing: 0) { TranscriptTypingRow(state: state) }
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
            .onScrollGeometryChange(
                for: TranscriptTop.self,
                of: { TranscriptTop($0) },
                action: { old, new in pageOlderNearTheTop(from: old, to: new) }
            )
            .onChange(of: state.messages.last?.id) { old, new in
                noteArrival(from: old, to: new)
            }
            .onScrollTargetVisibilityChange(idType: Message.ID.self, threshold: 0.01) { ids in
                seen.ids = ids
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
                if resumeIfReturning(proxy) {
                    return
                }
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
                let top = nearBottom && !state.hasNewerMessages ? nil : seen.top(in: state.messages)
                resume?.leave(.init(message: top, honoured: honoured))
                paging.hasUserIntent = false
                readingAnchor.cancel()
                latestJumpRequested = false
            }
            .modifier(TranscriptSearchMark(state: state, marked: $marked, markOn: $markOn))
            .modifier(TranscriptRotors(messages: state.messages, me: state.me, directory: state.directory))
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

    /// The floating button: to the end of what is loaded, or through the
    /// same latest jump as the list's own button when the newest messages
    /// are not loaded.
    private func jumpToLatest(_ action: TranscriptLatestJump.Action, _ proxy: ScrollViewProxy) {
        switch action {
        case .scroll:
            guard let newest = state.messages.last?.id else { return }
            paging.hasUserIntent = false
            readingAnchor.cancel()
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(newest, anchor: .bottom) }
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
    private func resumeIfReturning(_ proxy: ScrollViewProxy) -> Bool {
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
        nearBottom = false
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
