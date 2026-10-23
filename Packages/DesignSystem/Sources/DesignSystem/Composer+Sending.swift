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
    /// what was sent.
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
            if outside.people.isEmpty {
                finish(message)
            } else {
                pendingInvite = PendingInvite(
                    message: message, outsiders: outside, place: mentions?.place ?? "space",
                    canAddBeforeSending: mentions?.addAndSend != nil
                )
            }
        }
    }

    /// "Add and Send": the message adds them, or the host adds them and then
    /// sends. Either way the draft clears now, as for any send; a refused add
    /// hands the message back the way a refused send does.
    func add(_ invite: PendingInvite) {
        switch invite.adding {
        case .byMention:
            finish(invite.message.settingMode(.invite, for: invite.people))
        case .beforeSending:
            guard let addAndSend = mentions?.addAndSend else { return }
            if ComposerSendGate.clears(
                draft: draft.composed(formatting: allowsFormatting),
                sent: invite.message
            ) {
                draft.clear()
            }
            addAndSend(invite.message, invite.people)
        case .unavailable:
            return
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
