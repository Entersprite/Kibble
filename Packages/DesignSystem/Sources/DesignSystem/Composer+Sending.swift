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
        guard scheduling?.isSubmitting != true || draft.editing != nil else { return }
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
            if sendWithDraftSync(message) {
                return
            }
            clearForSubmission()
            send(message)
            return
        }
        guard pendingInvite == nil, let attempt = sendGate.begin() else { return }
        let composition = draft.syncedComposition
        checking = message
        Task { @MainActor in
            let outside = await ask(message)
            guard sendGate.attempt == attempt else { return }
            sendGate.cancel()
            checking = nil
            if outside.people.isEmpty {
                finish(message, matching: composition)
            } else {
                pendingInvite = PendingInvite(
                    message: message, composition: composition,
                    outsiders: outside, place: mentions?.place ?? "space",
                    canAddBeforeSending: mentions?.addAndSend != nil
                )
            }
        }
    }

    /// "Add and Send": the message adds them, or the host adds them and then
    /// sends. Either way the draft clears now, as for any send; a refused add
    /// hands the message back the way a refused send does.
    func add(_ invite: PendingInvite) {
        pendingInvite = nil
        switch invite.adding {
        case .byMention:
            finish(invite.message.settingMode(.invite, for: invite.people), matching: invite.composition)
        case .beforeSending:
            guard let addAndSend = mentions?.addAndSend else { return }
            if canClearSubmission(invite.message, matching: invite.composition) {
                if let composition = invite.composition, let submit = draftSync?.addAndSend {
                    submit(invite.message, composition, invite.people)
                    draft.clear()
                    return
                }
                clearForSubmission()
            }
            addAndSend(invite.message, invite.people)
        case .unavailable:
            return
        }
    }

    func canClearSubmission(_ message: ComposedMessage, matching composition: ComposedMessage?) -> Bool {
        draft.editing == nil && draft.syncedComposition == composition
            && ComposerSendGate.clears(draft: draft.composed(formatting: allowsFormatting), sent: message)
    }

    func retirePendingSubmission() {
        let unsent = pendingInvite?.message ?? checking
        sendGate.cancel()
        pendingInvite = nil
        checking = nil
        if let unsent {
            mentions?.keepHere?(unsent)
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
