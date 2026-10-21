import ChatKit
import SwiftUI

extension Composer {
    /// Text, or a staged file that is not already on its way.
    var canSubmit: Bool {
        !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachments
            .contains { !$0.isUploading }
    }

    /// Clears optimistically. The message comes back through the event stream
    /// and lands in the store; the field emptying immediately is what makes the
    /// app feel like it did something.
    /// Without a way to ask who is outside, sends at once. With one, asks;
    /// anyone outside brings up the confirmation (mention non-members spec
    /// §2). One Return at a time, and the draft cleared only if it still says
    /// what was sent (review focus 3 and 4).
    func submit() {
        switch ComposerEditKeys.submitAction(draft: draft, canSend: canSubmit) {
        case .nothing:
            return
        case .save:
            if let ended = draft.endEditing(formatting: allowsFormatting) {
                editing?.save(ended.messageID, ended.message)
                editing?.ended()
            }
            return
        case .send:
            break
        }
        let message = draft.composed(formatting: allowsFormatting)
        guard let ask = mentions?.nonMembers else {
            draft.clear()
            send(message)
            return
        }
        guard sendGate.begin() else { return }
        checking = message
        Task { @MainActor in
            defer {
                sendGate.end()
                checking = nil
            }
            let outside = await ask(message)
            if outside.isEmpty {
                finish(message)
            } else {
                pendingInvite = PendingInvite(message: message, people: outside)
            }
        }
    }

    /// Return does something: sends, or saves an edit.
    var canAct: Bool {
        ComposerEditKeys.submitAction(draft: draft, canSend: canSubmit) != .nothing
    }

    func begin(_ request: ComposerEditRequest?) {
        guard let request, let editing else { return }
        draft.beginEditing(request.messageID, with: request.message, formatting: allowsFormatting)
        editing.began(request.messageID)
        isFocused = true
        focusRequest += 1
    }

    func cancelEdit() {
        guard draft.endEditing(formatting: allowsFormatting) != nil else { return }
        editing?.ended()
    }
}
