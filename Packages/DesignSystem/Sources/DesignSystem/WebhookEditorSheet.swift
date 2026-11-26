import ChatKit
import Foundation
import SwiftUI

/// What the webhook editor holds: a name, and an avatar address that is
/// either empty or HTTPS. Any length limit is the server's to check; its
/// refusal is shown in the sheet.
struct WebhookDraft: Equatable {
    /// The webhook being edited; nil for a new one.
    let id: String?
    var name: String
    var avatarURL: String

    init(_ webhook: ConversationWebhook?) {
        id = webhook?.id
        name = webhook?.name ?? ""
        avatarURL = webhook?.avatarURL?.absoluteString ?? ""
    }

    var isValid: Bool {
        !trimmedName.isEmpty && isAvatarValid
    }

    /// Empty, or an `https` address with a host.
    var isAvatarValid: Bool {
        let text = trimmedAvatar
        guard !text.isEmpty else { return true }
        guard let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host(), !host.isEmpty else { return false }
        return true
    }

    /// Create for a new webhook, Save for this one.
    var mutation: ConversationMutation {
        .saveWebhook(id: id, name: trimmedName, avatarURL: trimmedAvatar)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAvatar: String {
        avatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// New Webhook / Edit Webhook, a small sheet over the Info sheet: Name and
/// an optional Avatar URL, then Cancel and Create or Save.
///
/// Create sends at once and the sheet stays until the server answers: it
/// closes on success, and on a refusal keeps what was typed and says why.
/// It has its own buttons and never touches the Info sheet's draft.
struct WebhookEditorSheet: View {
    let conversationName: String
    let state: ChatSceneState
    let actions: ConversationBrowserActions

    @Environment(\.dismiss) private var dismiss
    @State private var draft: WebhookDraft
    /// Create or Save was sent and its answer hasn't arrived.
    @State private var sent = false
    /// The write was seen submitting.
    @State private var started = false
    /// The last answer seen, for the check a moment after sending.
    @State private var latest = Answer()
    /// Whether a send has failed here, so a refusal is shown in this sheet.
    @State private var attempted = false

    init(
        webhook: ConversationWebhook?,
        conversationName: String,
        state: ChatSceneState,
        actions: ConversationBrowserActions
    ) {
        self.conversationName = conversationName
        self.state = state
        self.actions = actions
        _draft = State(initialValue: WebhookDraft(webhook))
    }

    private var isNew: Bool {
        draft.id == nil
    }

    /// `mutate` drops a write while one is on its way or the details need reloading.
    private var busy: Bool {
        let browser = state.browser
        return browser.isSubmitting || browser.needsReconciliation || browser.isLoadingAllParticipants
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("Required"))
                TextField("Avatar URL", text: $draft.avatarURL, prompt: Text("Optional"))
            } footer: {
                if !draft.isAvatarValid {
                    Text("Use an address that starts with https://.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .disabled(sent)
            // The Info sheet's header, which shows a refused save, is under this sheet.
            if attempted, !sent, let error = state.browser.panelError {
                Section {
                    SheetErrorRow(message: error)
                    // A refused write leaves the details to reload before another try.
                    if state.browser.needsReconciliation, let id = state.browser.panelTarget {
                        Button("Reload Details") { actions.details(id, false) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaBar(edge: .top) {
            SheetHeader(
                title: isNew ? "New Webhook" : "Edit Webhook",
                message: "Posts to \(conversationName)"
            )
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 250, idealHeight: 270)
        .toolbar { buttons }
        .onChange(of: answer, initial: true) { _, now in
            latest = now
            guard sent else { return }
            if now.isSubmitting {
                started = true
            } else if started || now.error != nil {
                finish(now.error)
            }
        }
        .task(id: sent) {
            // A quick answer can arrive without the write ever showing as
            // submitting; a moment later, the latest state tells how it went.
            guard sent else { return }
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled, sent, !latest.isSubmitting {
                finish(latest.error)
            }
        }
    }

    /// The model's side of a send: whether it is on its way, and any refusal.
    private struct Answer: Equatable {
        var isSubmitting = false
        var error: String?
    }

    private var answer: Answer {
        Answer(isSubmitting: state.browser.isSubmitting, error: state.browser.panelError)
    }

    /// Closes on success; on a refusal, stays with what was typed and the reason.
    private func finish(_ error: String?) {
        sent = false
        if error == nil {
            dismiss()
        }
    }

    @ToolbarContentBuilder private var buttons: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        if sent {
            // Beside Create or Save, the button it is the progress of.
            ToolbarItem(placement: .confirmationAction) {
                ProgressView().controlSize(.small)
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(isNew ? "Create" : "Save") {
                attempted = true
                started = false
                sent = true
                actions.mutate(draft.mutation)
            }
            .disabled(!draft.isValid || sent || busy)
        }
    }
}

/// The webhook the editor sheet is for: nil for a new one.
struct WebhookEditing: Identifiable {
    let webhook: ConversationWebhook?

    var id: String {
        webhook.map { "edit-\($0.id)" } ?? "new"
    }
}

/// One Copy URL request and how it went. Never holds the address itself.
struct WebhookCopy: Equatable {
    enum Phase: Equatable {
        case copying, copied
        case failed(String)
    }

    let webhook: String
    var phase = Phase.copying
    /// Tells this request from a later one for the same webhook.
    let token = UUID()

    /// The browser hands its reason over as `.unknown(text)`.
    static func message(for error: ChatError) -> String {
        switch error {
        case let .unknown(text) where !text.isEmpty: text
        case let .server(_, message) where !message.isEmpty: message
        default: "The URL couldn’t be copied. Try again."
        }
    }
}
