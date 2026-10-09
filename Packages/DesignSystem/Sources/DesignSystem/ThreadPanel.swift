import ChatKit
import SwiftUI

/// Where the panel scrolls, the transcript's rule on the panel's messages
/// (`TranscriptScroll`): a reply it was opened at, once, else the newest.
enum ThreadPanelScroll {
    static func destination(panel: ThreadPanelState, honored: Message.ID?) -> TranscriptScroll.Destination? {
        TranscriptScroll.destination(messages: panel.messages, target: panel.scrollTarget, honoured: honored)
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
/// Its title sits in the window toolbar's band, as the conversation's does,
/// and its Follow and Close are toolbar items (`ThreadFollowButton`).
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

    /// The title is a bar the replies scroll under, raised into the band so
    /// it sits level with the window's title. Below the band, with a divider,
    /// it left the band empty above it (session 63).
    var body: some View {
        ThreadPanelList(panel: panel, state: state, actions: actions, own: own)
            .safeAreaBar(edge: .top, spacing: 0) {
                ColumnTitle(title: "Thread", subtitle: panel.conversationTitle)
                    .padding(.leading, ColumnTitle.inset)
                    // In the band, clear of Follow and Close above it.
                    .padding(.trailing, band > 0 ? ThreadFollowButton.reserve : ColumnTitle.inset)
                    .padding(.vertical, band > 0 ? 0 : 8)
                    .frame(maxWidth: .infinity, minHeight: band, alignment: .leading)
            }
            // Soft, as the toolbar's own: a bar's automatic style here is the
            // hard one, a nearly opaque band (session 63, the owner's eyes).
            .scrollEdgeEffectStyle(.soft, for: .top)
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
    /// "Message the thread".
    @ViewBuilder private var composer: some View {
        if state.capabilities.canSendMessages, let conversation = state.selectedConversation {
            Composer(
                placeholder: "the thread",
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
                // The thread open at call time, not captured as `sendHere` is: safe only
                // while these mentions have no `nonMembers`, so nothing is awaited first.
                send: threads.sendReply
            )
            // The draft belongs to its thread (ruling 6): another thread gets
            // a fresh composer, so nothing typed here is sent there. Keyed by
            // conversation and thread, since a thread id is unique only in
            // its conversation.
            .id(ThreadListItem.Key(conversation: panel.thread.conversationID, thread: panel.thread.id))
        }
    }
}

/// Follow, as a toolbar item at the window's trailing edge, which is always
/// over the panel. **Each item at its own size:** an item sized to the panel
/// was not laid out again when the panel's width changed (past the window's
/// edge after one resize, gone after the next), and a flexible one was held
/// at its minimum (session 63). Close is its own item, apart from this one
/// (`ThreadSplit`), as the composer's buttons are.
struct ThreadFollowButton: View {
    let panel: ThreadPanelState
    let threads: ThreadActions

    /// How far the panel's title keeps from the window's trailing edge: both
    /// items at their widest ("Following"), the space between them, the
    /// toolbar's margin, and 8 pt (measured, session 63).
    static let reserve: CGFloat = 158

    var body: some View {
        Button {
            threads.setFollowed(!isFollowed)
        } label: {
            Label(ThreadsPresentation.followTitle(isFollowed: isFollowed), systemImage: followSymbol)
                // A toolbar draws icons alone, and a bare + reads as "new".
                .labelStyle(.titleAndIcon)
        }
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

    var body: some View {
        Button {
            threads.close()
        } label: {
            Label("Close Thread", systemImage: ThreadsPresentation.closeSymbol)
                .labelStyle(.iconOnly)
        }
        .help("Close Thread")
    }
}

/// The panel's messages, as plain stacks in a scroll view.
struct ThreadPanelList: View {
    let panel: ThreadPanelState
    let state: ChatSceneState
    let actions: ChatSceneActions
    let own: (Message) -> OwnMessageHandlers?
    /// The reply this panel last scrolled to, so it is honored once.
    @State private var honored: Message.ID?

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
            .onChange(of: TranscriptScroll.Trigger(panel), initial: true) {
                switch ThreadPanelScroll.destination(panel: panel, honored: honored) {
                case let .message(id)?:
                    honored = id
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
            message: message, state: state,
            loadAttachment: actions.loadAttachment, openAttachment: actions.openAttachment,
            loadRemoteImage: actions.loadRemoteImage,
            downloads: state.downloads, attachmentFiles: actions.attachmentFiles,
            reactions: actions.reactions, own: own(message)
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
