import ChatKit
import SwiftUI

/// The whole window: sidebar, transcript, composer.
///
/// Everything it draws arrives in `state`, and everything it wants arrives back
/// through `actions`. It has never heard of a database or a backend, which is
/// what makes the same view work against a fixture, a live bridge, or a server.
public struct ChatWindow: View {
    let state: ChatSceneState
    let actions: ChatSceneActions
    /// Set while the selected account is not running: its content column
    /// says why, in place of the empty state.
    let unavailable: AccountUnavailable?

    /// The edit a menu asked for, the message being edited, and the message
    /// whose deletion awaits confirmation (edit spec §5). Not `private`:
    /// `ChatWindow+Editing.swift` reads and writes them.
    @State var editRequest: ComposerEditRequest?
    @State var editingMessage: Message.ID?
    @State var pendingDelete: Message?
    @State var pendingForward: ForwardMessageSelection?
    @State var transcriptQuote: ComposerQuoteRequest?
    @State var panelQuote: ComposerQuoteRequest?
    /// Moved on at the selected DM partner's next boundary, so the header's
    /// words change on time (spec §6.3). Read by `subtitle` as a floor for
    /// `now`, which is what makes SwiftUI redraw it.
    @State var headerClock = Date.now
    /// The height of the toolbar's band over the thread column, where the
    /// panel raises its title (`ChatWindow+ThreadColumn.swift`).
    @State var threadBand: CGFloat = 0
    /// Where each account's transcript was, so switching back returns there.
    @State private var transcriptPositions = TranscriptPositions()

    public init(state: ChatSceneState, actions: ChatSceneActions, unavailable: AccountUnavailable? = nil) {
        self.state = state
        self.actions = actions
        self.unavailable = unavailable
    }

    /// Three columns: the sidebar, the conversation, and the open thread
    /// (session 64). **The thread is a real split view column, not a view
    /// inside the conversation's**, because a column of its own is what gives it
    /// a titlebar section, and a section is what gives its scroll-edge blur a
    /// backdrop group of its own. Two blurred bands in one section share one
    /// group, and the second drew a flat gray (session 64, measured in
    /// composited pixels, and how Mail builds its viewer). `ThreadColumnBridge`
    /// says what SwiftUI does not do for it. The sidebar cannot be hidden (the
    /// owner, session 64: it is to be redesigned).
    public var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            ConversationList(state: state, actions: actions)
                .accountUnavailable(unavailable != nil)
                .navigationSplitViewColumnWidth(
                    min: SidebarColumnLayout.minimumWidth,
                    ideal: SidebarColumnLayout.idealWidth
                )
                .toolbar(removing: .sidebarToggle)
                .toolbar {
                    if let browser = actions.browser {
                        ConversationSidebarTools(capabilities: state.capabilities, actions: browser)
                    }
                }
        } content: {
            VStack(spacing: 0) {
                if unavailable == nil {
                    StatusStrip(state: state, actions: actions)
                }
                if let bar = state.search.bar, let search = actions.search,
                   state.selectedConversation != nil {
                    SearchResultsBar(bar: bar, state: state, actions: search)
                }
                ZStack {
                    // Only while a page is open: its search field and toolbar
                    // items belong to the page and leave with it.
                    if state.browser.page != nil {
                        ConversationDirectoryView(state: state, actions: actions)
                    } else {
                        if state.showingMentions {
                            MentionsPane(items: state.mentions, status: state.mentionsStatus, me: state.me) {
                                actions.openMention?($0, $1)
                            }
                            // Its selected row is one account's message.
                            .id(state.accountID)
                        } else if state.threads.showingList, let threads = actions.threads {
                            ThreadsPane(
                                items: state.threads.items,
                                me: state.me,
                                directory: state.directory
                            ) {
                                threads.openItem($0, $1)
                            }
                            .id(state.accountID)
                        } else if let conversation = state.selectedConversation {
                            // `safeAreaInset`, so the transcript scrolls under the
                            // composer rather than being hidden behind it the way an
                            // `overlay` would leave it.
                            //
                            // **A gradient, not a material.** Messages does not blur
                            // behind its field - it fades the transcript into the
                            // window's own background. Two earlier attempts got this
                            // wrong from opposite directions: `.bar` drew a flat grey
                            // slab, and `safeAreaBar` brought the system's blurred
                            // backdrop. `ComposerScrim` is the fade itself.
                            MessageList(
                                state: state,
                                loadAttachment: actions.loadAttachment,
                                openAttachment: actions.openAttachment,
                                loadRemoteImage: actions.loadRemoteImage,
                                downloads: state.downloads,
                                attachmentFiles: actions.attachmentFiles,
                                reactions: actions.reactions,
                                threads: offeredThreadActions,
                                loadOlderMessages: actions.loadOlderMessages,
                                loadNewerMessages: actions.loadNewerMessages,
                                checkMessageDelivery: actions.checkMessageDelivery
                            )
                            .ownMessages(transcriptHandlers)
                            .meetingVisibility(actions.visibleMeetingMessages)
                            .resuming(transcriptPositions.resume(
                                account: state.accountID, conversation: state.selectedConversation?.id
                            ))
                            .id(AccountScoped(account: state.accountID, value: state.sidebarSelection))
                            .safeAreaInset(edge: .bottom, spacing: 0) {
                                VStack(spacing: 0) {
                                    TypingStrip(state: state)
                                    composer(for: conversation)
                                }
                                .background(alignment: .bottom) { ComposerScrim() }
                            }
                            .modifier(FileDropTarget(stage: dropStage))
                        } else if let unavailable {
                            AccountUnavailableView(unavailable: unavailable)
                        } else {
                            ContentUnavailableView(
                                "Pick a conversation",
                                systemImage: "sidebar.left",
                                description: Text("Choose one from the sidebar to read it.")
                            )
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .task(id: nextHeaderRedraw) { await waitForHeaderRedraw() }
            // Draws nothing; keeps the toolbar, so its band is 52 pt and two
            // rows, and the thread's section (session 65, `ThreadColumnBridge`).
            .toolbar {
                ToolbarSpacer(.flexible)
                if showsDetailsButton, let conversation = state.selectedConversation,
                   let browser = actions.browser {
                    ToolbarItem(placement: .primaryAction) {
                        Button(
                            state.meetingSeries == nil ? "Conversation Details" : "Latest Meeting Details",
                            systemImage: "info.circle"
                        ) {
                            browser.details(conversation.id, false)
                        }
                    }
                }
                // Each its own round glass: neighboring items share one capsule.
                if showsDetailsButton, callConversation != nil, actions.call != nil {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
                if let callConversation, let call = actions.call {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Call", systemImage: "phone") { call(callConversation) }
                            .help("Start audio call")
                    }
                }
                if let videoCallConversation, let videoCall = actions.videoCall {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    ToolbarItem(placement: .primaryAction) {
                        Button("Video Call", systemImage: "video") { videoCall(videoCallConversation) }
                            .help("Start video call")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: ThreadColumnLayout.minimumWidth, ideal: 640)
        } detail: {
            threadColumn
        }
        #if os(macOS)
        .background { ThreadColumnBridge(isOpen: threadColumnShown) }
        #endif
        .onChange(of: state.selectedConversation?.id) {
            editRequest = nil
            editingMessage = nil
        }
        .onChange(of: state.threads.panel?.thread.id) { forgetPanelEdit() }
        // What was pending names the other account's messages.
        .onChange(of: state.accountID) {
            transcriptQuote = nil
            panelQuote = nil
            editRequest = nil
            editingMessage = nil
            pendingDelete = nil
            pendingForward = nil
            forgetPanelEdit()
        }
        .modifier(DeleteConfirmation(pending: $pendingDelete, delete: actions.messages?.delete))
        .sheet(item: $pendingForward) { selection in
            ForwardMessageSheet(message: selection.message, state: state, send: actions.forwardMessage)
                .id(AccountScoped(account: state.accountID, value: selection.id))
        }
        .overlay { searchOverlay }
        .modifier(ConversationPanelPresentation(state: state, actions: actions))
        .environment(\.sceneImageLoader, actions.imageLoader)
        .environment(\.openEmbeddedMedia, actions.openEmbeddedMedia)
        .environment(\.invokeCardAction, actions.invokeCardAction)
    }

    /// The bar's content: the field, or why there isn't one.
    @ViewBuilder private func composer(for conversation: Conversation) -> some View {
        if state.capabilities.canSendMessages {
            Composer(
                placeholder: (state.meetingSeries?.title ?? Display.title(
                    of: conversation,
                    directory: state.directory,
                    me: state.me
                )) + (state.sendingAs.map { " as \($0)" } ?? ""),
                activity: { actions.typingActivity?(conversation.id, nil, $0) },
                restoring: state.failedDraft,
                onRestored: actions.draftRestored,
                attachments: state.stagedAttachments,
                attachmentActions: actions.composerAttachments,
                mentions: state.capabilities.canMention
                    ? ComposerMentions(
                        candidates: state.mentionCandidates,
                        includeAll: conversation.kind == .space,
                        directory: state.directoryResults,
                        queryChanged: actions.directoryQuery,
                        outsidePicked: actions.memberPicked,
                        // Asked only where outside people can be offered: a
                        // space, on a backend that can mention them.
                        nonMembers: state.capabilities.canMentionNonMembers && conversation.kind == .space
                            ? actions.nonMembers : nil,
                        sendHere: actions.sendTo.map { sendTo in { sendTo($0, conversation.id) } },
                        keepHere: actions.keepDraft.map { keep in { keep($0, conversation.id) } }
                    )
                    : nil,
                editing: composerEditing(),
                emoji: actions.reactions,
                initialDraft: state
                    .composerDrafts[ComposerDraftAddress(conversation: conversation.id)] ?? .init(),
                preserveDraft: actions.preserveDraft.map { preserve in
                    { preserve(ComposerDraftAddress(conversation: conversation.id), $0) }
                },
                allowsFormatting: state.capabilities.canFormatMessages,
                quoteRequest: transcriptQuote?.quote.conversation == conversation.id ? transcriptQuote : nil,
                onQuoteAdopted: { transcriptQuote = nil },
                quoteDirectory: state.directory,
                send: actions.send
            )
            // The draft belongs to the conversation it was typed in. Without
            // this the branch keeps its identity across a selection change,
            // `@State draft` survives, and a half-typed line addressed to one
            // person posts to whoever was opened next. Cheap to miss,
            // expensive to send. Keyed by account too: two accounts can
            // share a space.
            .id(AccountScoped(account: state.accountID, value: state.sidebarSelection))
        } else {
            // Not a disabled field: a greyed-out composer invites the user to
            // keep clicking it. Saying why is kinder.
            Text("This backend cannot send messages yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
    }

    /// Where a drop goes, if anywhere: only where the composer is drawn and
    /// the host can stage files.
    private var dropStage: (([URL]) -> Void)? {
        guard state.capabilities.canSendMessages,
              ThreadEditRouting.takesDrops(
                  in: .transcript,
                  editing: editOwner,
                  anyEdit: editingMessage != nil
              )
        else { return nil }
        return actions.composerAttachments?.stage
    }
}

/// Files dropped on the conversation are staged in its composer, with a tint
/// while a drag is over it. No stage, no drop target, so a backend that cannot
/// upload refuses the drag rather than swallowing it.
struct FileDropTarget: ViewModifier {
    let stage: (([URL]) -> Void)?
    @State private var isTargeted = false

    /// Always attached, refusing when there is nowhere to stage. Drawing
    /// `content` bare in a second branch gave it a new identity whenever
    /// drops turned off, which they do when an edit begins, so the composer
    /// under it was rebuilt mid-edit and Up arrow's edit was lost (session 60
    /// review, Important 1). A refused drag shows no tint; what the cursor
    /// shows over it is `[Verify]`.
    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                guard let stage else { return false }
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                stage(files)
                return true
            } isTargeted: { isTargeted = $0 }
            .overlay {
                if isTargeted, stage != nil {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .background(
                            Color.accentColor.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// The wash behind the composer - what Messages has instead of a blurred bar.
///
/// The window's own background, ramping from nothing to 75%, so the transcript
/// settles toward the ground it sits on rather than being brightened by a
/// white overlay.
///
/// **What this can and cannot do.** Painting the background over its own ground
/// is invisible by construction - the empty part of the transcript will not
/// change at any opacity. The only thing this affects is *content*: message
/// bubbles passing behind the composer fade toward the background. That is the
/// whole effect, and it is why very low values read as nothing happening. A
/// visible band, as opposed to a fade, needs a colour that differs from the
/// background - a white lift or a black shadow - not the background itself.
///
/// A mask rather than colours in the gradient, because the semantic
/// `.background` is a `ShapeStyle` and cannot be a `LinearGradient` stop. The
/// mask's alpha is the fill's opacity, so `.black.opacity(0.75)` paints the
/// background at 75% - and it follows the appearance, which a literal colour
/// would not. This package builds for iOS too.
///
/// `alignment: .bottom` plus `ignoresSafeArea(edges: .bottom)` at the call site
/// carries it into the window's bottom safe area, so the wash reaches the edge
/// rather than stopping at the composer's own bounds.
struct ComposerScrim: View {
    var body: some View {
        Rectangle()
            .fill(.background)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.30), location: 0.55),
                        .init(color: .black.opacity(0.75), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .allowsHitTesting(false)
            .ignoresSafeArea(edges: .bottom)
    }
}

struct TypingStrip: View {
    let state: ChatSceneState

    var body: some View {
        if !state.typing.isEmpty {
            let names = state.typing.map { Display.name(of: $0, in: state.directory) }
            Text(names.count == 1 ? "\(names[0]) is typing…" : "\(names.count) people are typing…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
        }
    }
}
