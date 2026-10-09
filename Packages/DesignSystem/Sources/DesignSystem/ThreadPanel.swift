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

    /// Whether an edit outlives the panel changing thread or closing: only
    /// the transcript's. The panel's composer goes with its thread without
    /// ending its edit, so the window forgets that edit, or reopening the
    /// thread would begin it again.
    static func survivesPanelChange(_ message: Message.ID, transcript: [Message]) -> Bool {
        owner(of: message, transcript: transcript, panel: []) == .transcript
    }
}

/// The thread on the right (threads spec §5.2): a header with Follow, the
/// first message and its replies drawn by the transcript's own bubble, and a
/// composer of its own.
struct ThreadPanel: View {
    let panel: ThreadPanelState
    let state: ChatSceneState
    let actions: ChatSceneActions
    let threads: ThreadActions
    /// Each bubble's menus (`ChatWindow.panelHandlers(for:)`).
    let own: (Message) -> OwnMessageHandlers?
    let editing: ComposerEditing?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ThreadPanelList(panel: panel, state: state, actions: actions, own: own)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    composer
                        .background(alignment: .bottom) { ComposerScrim() }
                }
        }
        #if os(macOS)
        // Esc closes the panel only when nothing inside used it (ruling 5).
        .onExitCommand { threads.close() }
        #endif
    }

    private var isFollowed: Bool {
        panel.thread.isFollowed ?? false
    }

    private var followSymbol: String {
        isFollowed ? ThreadsPresentation.followingSymbol : ThreadsPresentation.followSymbol
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Thread")
                    .font(.headline)
                Text(panel.conversationTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                threads.setFollowed(!isFollowed)
            } label: {
                Label(ThreadsPresentation.followTitle(isFollowed: isFollowed), systemImage: followSymbol)
            }
            .controlSize(.small)
            // The toggle changes only once the server agreed (spec §3).
            .disabled(panel.followPending)
            Button {
                threads.close()
            } label: {
                Label("Close Thread", systemImage: ThreadsPresentation.closeSymbol)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Close Thread")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// `Composer` writes "Message " before its placeholder, so this reads
    /// "Message the thread".
    @ViewBuilder private var composer: some View {
        if state.capabilities.canSendMessages, let conversation = state.selectedConversation {
            Composer(
                placeholder: "the thread",
                mentions: state.capabilities.canMention
                    ? ComposerMentions(
                        candidates: state.mentionCandidates,
                        includeAll: conversation.kind == .space
                    )
                    : nil,
                editing: editing,
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
