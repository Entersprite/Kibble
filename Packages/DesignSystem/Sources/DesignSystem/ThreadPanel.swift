import ChatKit
import SwiftUI

/// Where the panel scrolls, the transcript's rule on the panel's messages
/// (`TranscriptScroll`): a reply it was opened at, once, else the newest.
enum ThreadPanelScroll {
    static func destination(
        panel: ThreadPanelState, honored: TranscriptScroll.Request?
    ) -> TranscriptScroll.Destination? {
        TranscriptScroll.destination(
            messages: panel.messages, target: panel.scrollTarget, generation: panel.scrollGeneration,
            honoured: honored
        )
    }
}

/// Which composer an edit belongs to (ruling 4). A thread's first message is
/// in both lists; it was written in the transcript, so it is edited there.
enum ThreadEditRouting {
    enum Owner: Equatable {
        case transcript
        case panel
    }

    static func owner(of message: Message.ID, transcript: [Message], panel: [Message]) -> Owner? {
        if transcript.contains(where: { $0.id == message }) {
            return .transcript
        }
        return panel.contains { $0.id == message } ? .panel : nil
    }

    /// Whether a composer takes an edit, from a menu or Up arrow: only while
    /// the other one is not editing. A request routed to one composer does
    /// not end the other's edit, so offering it would put both in edit mode
    /// (threads spec §4.3: one edit at a time across both).
    static func offersEdit(in composer: Owner?, editing: Owner?) -> Bool {
        editing == nil || composer == editing
    }

    /// Whether a composer takes dropped files: only while it is not editing,
    /// since an edit never carries files (edit spec §5). The other
    /// composer's edit leaves it free. An edit neither list holds (its
    /// message deleted meanwhile) still has its composer in edit mode, and
    /// which one is unknown, so neither takes files then.
    static func takesDrops(in composer: Owner, editing: Owner?, anyEdit: Bool) -> Bool {
        guard anyEdit else { return true }
        return editing != nil && editing != composer
    }

    /// Whether an edit outlives the panel changing thread or closing: only
    /// the transcript's. The panel's composer goes with its thread without
    /// ending its edit, so the window forgets that edit, or reopening the
    /// thread would begin it again.
    static func survivesPanelChange(_ message: Message.ID, transcript: [Message]) -> Bool {
        owner(of: message, transcript: transcript, panel: []) == .transcript
    }
}

/// The thread on the right (threads spec §5.2): the first message and its
/// replies drawn by the transcript's own bubble, and a composer of its own.
/// It fills the window's third column (`ChatWindow+ThreadColumn.swift`); its title
/// sits in that column's toolbar band, and its Follow and Close sit in the toolbar
/// (`ThreadFollowButton`, `ThreadCloseButton`).
struct ThreadPanel: View {
    let panel: ThreadPanelState
    let state: ChatSceneState
    let actions: ChatSceneActions
    let threads: ThreadActions
    /// Each bubble's menus (`ChatWindow.panelHandlers(for:)`).
    let own: (Message) -> OwnMessageHandlers?
    let editing: ComposerEditing?
    /// Where a drop on the panel goes (`ChatWindow.panelDropStage`).
    let dropStage: (([URL]) -> Void)?
    /// The height of the window toolbar's band above the panel, or 0 when
    /// something else is drawn between them (`StatusStrip`).
    let band: CGFloat
    /// How far the title keeps from the trailing edge while it sits in the
    /// band, clear of Follow and Close (`ThreadColumnLayout.titleReserve`).
    var titleReserve: CGFloat = ThreadColumnLayout.titleReserve(tools: 0)
    var quoteRequest: ComposerQuoteRequest?
    var onQuoteAdopted: (() -> Void)?

    /// The title is a bar the replies scroll under, raised into the band so
    /// it sits level with the window's title. Below the band, with a divider,
    /// it left the band empty above it (session 63).
    var body: some View {
        ThreadPanelList(panel: panel, state: state, actions: actions, own: own)
            .safeAreaBar(edge: .top, spacing: 0) {
                ColumnTitle(title: "Thread", subtitle: panel.conversationTitle)
                    .padding(.leading, ColumnTitle.inset)
                    // In the band, clear of Follow and Close above it.
                    .padding(.trailing, band > 0 ? titleReserve : ColumnTitle.inset)
                    .padding(.vertical, band > 0 ? 0 : 8)
                    .frame(maxWidth: .infinity, minHeight: band, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
                    .background(alignment: .bottom) { ComposerScrim() }
            }
            // Its own target: the conversation's covers the transcript
            // only, so a file dropped here goes to the thread.
            .modifier(FileDropTarget(stage: dropStage))
            .ignoresSafeArea(.container, edges: .top)
        #if os(macOS)
            // Esc closes the panel only when nothing inside used it (ruling 5).
            .onExitCommand { threads.close() }
        #endif
    }

    /// `Composer` writes "Message " before its placeholder, so this reads
    /// "Message the thread", and "… as ‹account›" while several are connected.
    @ViewBuilder private var composer: some View {
        if state.capabilities.canSendMessages, let conversation = state.selectedConversation {
            Composer(
                placeholder: "the thread" + (state.sendingAs.map { " as \($0)" } ?? ""),
                activity: { actions.typingActivity?(panel.thread.conversationID, panel.thread.id, $0) },
                restoring: panel.failedDraft,
                onRestored: {
                    threads.clearFailedDraft?(panel.thread.conversationID, panel.thread.id)
                },
                attachments: panel.stagedAttachments,
                attachmentActions: threads.attachments,
                mentions: state.capabilities.canMention
                    ? ComposerMentions(
                        candidates: state.mentionCandidates,
                        includeAll: conversation.kind == .space
                    )
                    : nil,
                editing: editing,
                emoji: actions.reactions,
                initialDraft: state.composerDrafts[ComposerDraftAddress(
                    conversation: panel.thread.conversationID, thread: panel.thread.id
                )] ?? .init(),
                preserveDraft: actions.preserveDraft.map { preserve in
                    { preserve(ComposerDraftAddress(
                        conversation: panel.thread.conversationID, thread: panel.thread.id
                    ), $0) }
                },
                allowsFormatting: state.capabilities.canFormatMessages,
                quoteRequest: quoteRequest,
                onQuoteAdopted: onQuoteAdopted,
                quoteDirectory: state.directory,
                // The thread open at call time, not captured as `sendHere` is: safe only
                // while these mentions have no `nonMembers`, so nothing is awaited first.
                send: threads.sendReply
            )
            // The draft belongs to its thread (ruling 6): another thread gets
            // a fresh composer, so nothing typed here is sent there. Keyed by
            // conversation and thread, since a thread id is unique only in
            // its conversation.
            .id(AccountScoped(
                account: state.accountID,
                value: ThreadListItem.Key(conversation: panel.thread.conversationID, thread: panel.thread.id)
            ))
        }
    }
}

/// Follow, beside Close in a toolbar item at the thread column's trailing edge
/// (`ThreadColumnBridge` puts a flexible space before it). **The item at its own
/// size:** one sized to the panel was not laid out again when the panel's
/// width changed (past the window's edge after one resize, gone after the
/// next), and a flexible one was held at its minimum (session 63).
///
/// The system's glass button in a capsule, in the control's own font.
struct ThreadFollowButton: View {
    let panel: ThreadPanelState
    let threads: ThreadActions

    /// The label's height: with the regular size's 4-point padding on each
    /// side, the button is as tall as Close beside it (31 pt, measured hosted).
    static let labelHeight = ComposerLayout.lineHeight - 8

    var body: some View {
        Button {
            threads.setFollowed(!isFollowed)
        } label: {
            Label(ThreadsPresentation.followTitle(isFollowed: isFollowed), systemImage: followSymbol)
                // A toolbar draws icons alone, and a bare + reads as "new".
                .labelStyle(.titleAndIcon)
                .frame(minHeight: Self.labelHeight)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        // The toggle changes only once the server agreed (spec §3).
        .disabled(panel.followPending)
    }

    private var isFollowed: Bool {
        panel.thread.isFollowed ?? false
    }

    private var followSymbol: String {
        isFollowed ? ThreadsPresentation.followingSymbol : ThreadsPresentation.followSymbol
    }
}

struct ThreadCloseButton: View {
    let threads: ThreadActions

    /// The composer's round button, so the two sets of buttons match.
    var body: some View {
        RoundGlassButton(title: "Close Thread", systemImage: ThreadsPresentation.closeSymbol) {
            threads.close()
        }
    }
}

/// The panel's messages, as plain stacks in a scroll view.
struct ThreadPanelList: View {
    let panel: ThreadPanelState
    let state: ChatSceneState
    let actions: ChatSceneActions
    let own: (Message) -> OwnMessageHandlers?
    /// The reply this panel last scrolled to, so it is honored once.
    @State private var honored: TranscriptScroll.Request?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let first = panel.firstMessage {
                        bubble(first)
                    }
                    divider
                    ForEach(panel.replies, id: \.id) { reply in
                        bubble(reply)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .environment(\.openURL, LinkPolicy.openURLAction)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if state.capabilities.receivesTypingState {
                    HStack {
                        let typists = ActivityPresentation.typists(state, thread: panel.thread.id)
                        if !typists.isEmpty {
                            TypingIndicator(members: typists, directory: state.directory, namesVisible: true)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading)
                    .padding(.horizontal, 12)
                }
            }
            .onChange(of: TranscriptScroll.Trigger(panel), initial: true) {
                switch ThreadPanelScroll.destination(panel: panel, honored: honored) {
                case let .message(id)?:
                    honored = TranscriptScroll.Request(id: id, generation: panel.scrollGeneration)
                    proxy.scrollTo(id, anchor: .center)
                case let .newest(id)?:
                    proxy.scrollTo(id, anchor: .bottom)
                case nil:
                    break
                }
            }
        }
    }

    /// No `openThread`: the panel is the thread, so its first message draws
    /// no mark.
    private func bubble(_ message: Message) -> some View {
        MessageBubble(
            message: message, state: MessageRowState(message: message, scene: state, showsThread: false),
            loadAttachment: actions.loadAttachment, openAttachment: actions.openAttachment,
            loadRemoteImage: actions.loadRemoteImage,
            attachmentFiles: actions.attachmentFiles,
            reactions: actions.reactions, own: own(message), checkDelivery: actions.checkMessageDelivery
        )
        .id(message.id)
    }

    private var divider: some View {
        HStack(spacing: 8) {
            VStack { Divider() }
            Text(ThreadsPresentation.hasReplies(panel.thread) ? ThreadMarkText
                .count(panel.thread) : "No replies yet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            VStack { Divider() }
        }
        .padding(.vertical, 6)
    }
}
