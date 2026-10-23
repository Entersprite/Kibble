import ChatKit
import SwiftUI

/// Settings' Space Email: the space's address with Copy, Receive email and
/// Delete Email Address…, or Create Email Address when it has none.
///
/// Each action is offered only where the server allows it, and each is sent
/// at once, not with the Settings draft. While one is on its way its row
/// shows the value it asks for, with a small progress indicator. Turning
/// delivery off and deleting the address are separate: deleting asks first,
/// because earlier email messages go with it.
///
/// The form that holds it loads the address (`ConversationBrowserActions.loadEmail`).
struct SpaceEmailSection: View {
    let spaceName: String
    let state: ChatSceneState
    let actions: ConversationBrowserActions

    @State private var confirmingDelete = false

    private var browser: ConversationBrowserScene {
        state.browser
    }

    /// `mutate` drops a write while reconciling or submitting.
    private var busy: Bool {
        browser.isSubmitting || browser.needsReconciliation
    }

    /// Nothing to show: no address, none to create, and nothing loading or wrong.
    private var isEmpty: Bool {
        guard let email = browser.email else { return !browser.isLoadingEmail && browser.emailError == nil }
        return email.address == nil && !email.canGenerate && browser.emailError == nil
    }

    var body: some View {
        if !isEmpty {
            Section("Space Email") {
                if let email = browser.email {
                    if let address = email.address {
                        addressRow(address)
                        delivery(email)
                        if email.canDelete {
                            deleteRow
                        }
                    } else if email.canGenerate {
                        HStack {
                            Button("Create Email Address") { actions.mutate(.generateEmail) }
                                .disabled(busy)
                            if browser.pendingMutation == .generateEmail {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                } else if browser.isLoadingEmail {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                }
                if let error = browser.emailError {
                    SheetErrorRow(message: error)
                }
            }
        }
    }

    private func addressRow(_ address: String) -> some View {
        HStack(spacing: 8) {
            Text(address)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button("Copy") { TextPasteboard.copy(address) }
                .help("Copy the email address")
        }
    }

    /// The switch shows the value on its way while a delivery change is pending.
    @ViewBuilder private func delivery(_ email: ConversationEmail) -> some View {
        let pending: Bool? = if case let .setEmailDelivery(value) = browser.pendingMutation {
            value
        } else {
            nil
        }
        if let enabled = pending ?? email.deliveryEnabled {
            Toggle(isOn: Binding(get: { enabled }, set: { actions.mutate(.setEmailDelivery($0)) })) {
                HStack(spacing: 6) {
                    Text("Receive email")
                    if pending != nil {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(!email.canChangeDelivery || busy)
        }
    }

    private var deleteRow: some View {
        HStack {
            Button("Delete Email Address…", role: .destructive) { confirmingDelete = true }
                .disabled(busy)
            if browser.pendingMutation == .deleteEmail {
                ProgressView().controlSize(.small)
            }
        }
        // On the one row: a section's modifiers can reach each of its rows.
        .alert("Delete the email address for \(spaceName)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { actions.mutate(.deleteEmail) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its address stops working, and earlier email messages in this space are deleted too.")
        }
    }
}
