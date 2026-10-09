import ChatKit
import SwiftUI

/// Editing and deleting the person's own messages, as the window sees it
/// (edit spec §5): which menu items exist, what the composer is told, and the
/// confirmation before a delete. The thread items share the menus, so their
/// gate is here too (threads spec §5).
extension ChatWindow {
    /// The thread actions, only where the selected conversation has replies
    /// (world field 27, `ThreadsPresentation.offersReplies`): a Meet chat gets
    /// no mark and no thread menu item (threads spec §5). The marks and the
    /// menus both read this, so they cannot disagree.
    var offeredThreadActions: ThreadActions? {
        ThreadsPresentation.offersReplies(in: state.selectedConversation) ? actions.threads : nil
    }

    /// What the bubbles' menus may offer: a `nil` handler where the backend
    /// cannot, and nothing at all without `actions.messages` or thread
    /// actions (`offeredThreadActions`).
    ///
    /// `markUnread` is offered from the transcript's handlers too, but
    /// `items(for:)` offers it only on a reply, and the transcript holds none.
    /// Both lists take these through a gate (`transcriptHandlers`,
    /// `panelHandlers(for:)`): one edit at a time across both composers.
    var ownHandlers: OwnMessageHandlers? {
        let threads = offeredThreadActions
        guard actions.messages != nil || threads != nil else { return nil }
        let summaries = state.threads.summaries
        return OwnMessageHandlers(
            me: state.me,
            edit: actions.messages != nil && state.capabilities.canEditMessages ? { message in
                editRequest = ComposerEditRequest(
                    messageID: message.id,
                    message: ComposedMessage(text: message.text, mentions: message.mentions)
                )
            } : nil,
            delete: actions.messages != nil && state.capabilities.canDeleteMessages
                ? { pendingDelete = $0 } : nil,
            replyInThread: threads.map { threads in { threads.open($0.threadID) } },
            markUnread: threads.map { threads in { threads.markUnread($0) } },
            hasReplies: { ThreadsPresentation.hasReplies(summaries[$0.threadID]) }
        )
    }

    /// The request is passed on only while its message is in the open
    /// conversation: switching rebuilds the composer, and a new one must not
    /// begin an edit left over from the conversation before.
    func composerEditing() -> ComposerEditing? {
        guard let messages = actions.messages, state.capabilities.canEditMessages else { return nil }
        let request = editRequest.flatMap { request in
            state.messages.contains { $0.id == request.messageID } ? request : nil
        }
        return ComposerEditing(
            request: request,
            newest: panelIsEditing ? nil : OwnMessageRule.newestEditable(in: state.messages, me: state.me),
            save: messages.save,
            began: { editingMessage = $0 },
            ended: {
                editingMessage = nil
                editRequest = nil
            }
        )
    }

    /// Whether the panel's composer holds the window's edit (ruling 4).
    var panelIsEditing: Bool {
        editOwner == .panel
    }
}

/// "Delete this message?" before a delete, which no one can undo.
struct DeleteConfirmation: ViewModifier {
    @Binding var pending: Message?
    let delete: ((Message.ID) -> Void)?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete this message?",
            isPresented: Binding(get: { pending != nil }, set: {
                if !$0 {
                    pending = nil
                }
            }),
            presenting: pending
        ) { message in
            Button("Delete", role: .destructive) { delete?(message.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It will be deleted for everyone.")
        }
    }
}
