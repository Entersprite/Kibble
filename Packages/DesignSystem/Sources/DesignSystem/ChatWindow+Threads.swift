import ChatKit
import SwiftUI

/// One edit at a time across the transcript's composer and the panel's
/// (ruling 4): both share `editRequest` and `editingMessage`, and each
/// composer takes an edit only while the other is not editing.
extension ChatWindow {
    /// Which composer holds the window's edit, if either.
    var editOwner: ThreadEditRouting.Owner? {
        editingMessage.flatMap { id in
            ThreadEditRouting.owner(
                of: id, transcript: state.messages, panel: state.threads.panel?.messages ?? []
            )
        }
    }

    /// The transcript's menus: no Edit… while the panel's composer edits.
    var transcriptHandlers: OwnMessageHandlers? {
        guard var handlers = ownHandlers else { return nil }
        if !ThreadEditRouting.offersEdit(in: .transcript, editing: editOwner) {
            handlers.edit = nil
        }
        return handlers
    }

    /// A panel bubble's menus: Edit… only where the message's composer may
    /// take it, and no "Reply in Thread", since the panel is that thread.
    func panelHandlers(for message: Message) -> OwnMessageHandlers? {
        guard var handlers = ownHandlers else { return nil }
        handlers.replyInThread = nil
        let composer = ThreadEditRouting.owner(
            of: message.id, transcript: state.messages, panel: state.threads.panel?.messages ?? []
        )
        if !ThreadEditRouting.offersEdit(in: composer, editing: editOwner) {
            handlers.edit = nil
        }
        return handlers
    }

    /// The panel's edit mode: the window's one edit request, when it belongs
    /// to the panel (ruling 4); Up arrow only while the transcript is not
    /// editing.
    func panelEditing() -> ComposerEditing? {
        guard let messages = actions.messages, state.capabilities.canEditMessages,
              let panel = state.threads.panel
        else { return nil }
        let request = editRequest.flatMap { request in
            ThreadEditRouting.owner(
                of: request.messageID, transcript: state.messages, panel: panel.messages
            ) == .panel ? request : nil
        }
        return ComposerEditing(
            request: request,
            newest: ThreadEditRouting.offersEdit(in: .panel, editing: editOwner)
                ? OwnMessageRule.newestEditable(in: panel.replies, me: state.me) : nil,
            save: messages.save,
            began: { editingMessage = $0 },
            ended: {
                editingMessage = nil
                editRequest = nil
            }
        )
    }

    /// Where a drop on the panel goes, if anywhere: the open thread's
    /// composer, when the host can stage files there and it is not editing.
    var panelDropStage: (([URL]) -> Void)? {
        guard state.capabilities.canSendMessages,
              ThreadEditRouting.takesDrops(in: .panel, editing: editOwner, anyEdit: editingMessage != nil)
        else { return nil }
        return offeredThreadActions?.attachments?.stage
    }

    /// The panel's composer goes with its thread and never says its edit
    /// ended: forget that edit when the panel changes thread or closes, so a
    /// reopened thread does not begin it again and the transcript takes
    /// files again. The transcript's own edit stays.
    func forgetPanelEdit() {
        if let id = editingMessage, !ThreadEditRouting.survivesPanelChange(id, transcript: state.messages) {
            editingMessage = nil
        }
        if let id = editRequest?.messageID,
           !ThreadEditRouting.survivesPanelChange(id, transcript: state.messages) {
            editRequest = nil
        }
    }
}
