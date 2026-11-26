import ChatKit
import SwiftUI

/// Info's Integrations: the conversation's apps and its webhooks, each group
/// shown only where its capability is advertised, with its Add button in
/// the header where the server allows adding.
///
/// Nothing here is a draft: each action is sent on its own, and the browser
/// reloads the list once the server confirms. A destructive one asks first.
/// Copy URL fetches a webhook's address only when asked and puts it straight
/// on the pasteboard; the address is never kept.
struct ConversationIntegrationsForm: View {
    let details: ConversationDetails
    let state: ChatSceneState
    let actions: ConversationBrowserActions

    /// Whether a refusal is shown here, beside what failed, so the sheet's
    /// header need not repeat it.
    @Binding var showsErrorInline: Bool

    @State private var addingApp = false
    @State private var editing: WebhookEditing?
    @State private var confirming: IntegrationConfirmation?
    @State private var copy: WebhookCopy?
    /// The last change sent from here, to put its refusal beside it.
    @State private var lastSent: ConversationMutation?

    init(
        details: ConversationDetails,
        state: ChatSceneState,
        actions: ConversationBrowserActions,
        showsErrorInline: Binding<Bool> = .constant(false),
        // The change last sent, in renders of its refusal.
        sent: ConversationMutation? = nil
    ) {
        self.details = details
        self.state = state
        self.actions = actions
        _showsErrorInline = showsErrorInline
        _lastSent = State(initialValue: sent)
    }

    private var browser: ConversationBrowserScene {
        state.browser
    }

    /// `mutate` drops a write while one is on its way or the details need reloading.
    private var busy: Bool {
        browser.isSubmitting || browser.needsReconciliation || browser.isLoadingAllParticipants
    }

    private var failure: IntegrationFailure? {
        IntegrationFailure.place(
            sent: lastSent, pending: browser.pendingMutation, error: browser.panelError,
            shown: IntegrationFailure.Shown(
                browser.integrations,
                showsApps: state.capabilities.canManageConversationApps,
                showsWebhooks: state.capabilities.canManageConversationWebhooks
            )
        )
    }

    private var title: String {
        Display.title(of: details.conversation, directory: state.directory, me: state.me)
    }

    var body: some View {
        Form {
            if let integrations = browser.integrations {
                if let error = browser.integrationsError {
                    loadFailure(error)
                }
                if state.capabilities.canManageConversationApps {
                    apps(integrations)
                }
                if state.capabilities.canManageConversationWebhooks {
                    webhooks(integrations)
                }
            } else if let error = browser.integrationsError {
                loadFailure(error)
            } else {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { actions.loadIntegrations() }
        .onChange(
            of: IntegrationFailure.Progress(
                pending: browser.pendingMutation, error: browser.panelError,
                integrations: browser.integrations
            )
        ) { _, now in
            // A success (seen finishing, or as the reload after it), or a reload
            // that cleared the error: a later error isn't this change's.
            if IntegrationFailure.forgetsSent(pending: now.pending, error: now.error) {
                lastSent = nil
            }
        }
        .onChange(of: failure != nil, initial: true) { _, shown in showsErrorInline = shown }
        .onDisappear { showsErrorInline = false }
        .sheet(isPresented: $addingApp) {
            AddAppSheet(conversationName: title, state: state, actions: actions) { send(.addApp($0)) }
        }
        .sheet(item: $editing) { editing in
            WebhookEditorSheet(
                webhook: editing.webhook, conversationName: title, state: state, actions: actions
            )
        }
        .alert(
            confirming.map { $0.title(in: title) } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { shown in
                if !shown {
                    confirming = nil
                }
            }),
            presenting: confirming
        ) { confirmation in
            Button(confirmation.button, role: .destructive) { send(confirmation.mutation) }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            if let message = confirmation.message {
                Text(message)
            }
        }
        .task(id: copy) { await settle(copy) }
    }

    /// Sends a change and remembers it, so a refusal can be shown beside it.
    private func send(_ mutation: ConversationMutation) {
        lastSent = mutation
        actions.mutate(mutation)
    }

    /// The refusal under what failed, with the reload a refused write needs.
    @ViewBuilder private func refusal(at place: IntegrationFailure) -> some View {
        if failure == place, let error = browser.panelError {
            SheetErrorRow(message: error)
            if browser.needsReconciliation {
                Button("Reload Details") { actions.details(details.conversation.id, false) }
            }
        }
    }

    private func loadFailure(_ error: String) -> some View {
        Section {
            SheetErrorRow(message: error)
            Button("Try Again") { actions.loadIntegrations() }
        }
    }

    private func header(
        _ title: String, add: String?, adding: Bool, action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if adding {
                ProgressView().controlSize(.mini)
            }
            Spacer(minLength: 8)
            if let add {
                Button(add, action: action)
                    .controlSize(.small)
                    .disabled(busy)
            }
        }
    }

    // MARK: Apps

    private func apps(_ integrations: ConversationIntegrations) -> some View {
        Section {
            refusal(at: .addingApp)
            ForEach(integrations.apps) { app in
                AppRow(app: app) { trailing(for: app) }
                    .contextMenu { appMenu(app) }
                refusal(at: .app(app.id))
            }
            if integrations.apps.isEmpty {
                Text("No apps yet").foregroundStyle(.secondary)
            }
        } header: {
            let adding = if case .addApp = browser.pendingMutation {
                true
            } else {
                false
            }
            header(
                "Apps", add: integrations.canAddApps ? "Add App…" : nil, adding: adding,
                action: {
                    lastSent = nil
                    addingApp = true
                }
            )
        }
    }

    private func trailing(for app: ConversationApp) -> some View {
        HStack(spacing: 8) {
            if browser.pendingMutation == .removeApp(app.id) {
                ProgressView().controlSize(.small)
            }
            if !app.allowedActions.isDisjoint(with: ["message", "removeApp"]) {
                RowActionsMenu(name: AppName.of(app)) { appMenu(app) }
            }
        }
    }

    @ViewBuilder private func appMenu(_ app: ConversationApp) -> some View {
        if app.allowedActions.contains("message") {
            Button("Message", systemImage: DirectoryMenuSymbols.message) {
                lastSent = nil
                actions.openApp(app.id)
            }
            .disabled(browser.isSubmitting)
        }
        if app.allowedActions.contains("removeApp") {
            Divider()
            Button("Remove…", systemImage: DirectoryMenuSymbols.remove, role: .destructive) {
                confirming = .removeApp(app)
            }
            .disabled(busy)
        }
    }

    // MARK: Webhooks

    private func webhooks(_ integrations: ConversationIntegrations) -> some View {
        Section {
            ForEach(integrations.webhooks) { webhook in
                HStack(spacing: 10) {
                    WebhookIcon(url: webhook.avatarURL)
                    Text(webhook.name).lineLimit(1)
                    Spacer(minLength: 8)
                    trailing(for: webhook)
                }
                .contentShape(Rectangle())
                .contextMenu { webhookMenu(webhook) }
                if let copy, copy.webhook == webhook.id, case let .failed(message) = copy.phase {
                    SheetErrorRow(message: message)
                }
                refusal(at: .webhook(webhook.id))
            }
            if integrations.webhooks.isEmpty {
                Text("No webhooks yet").foregroundStyle(.secondary)
            }
        } header: {
            let adding = if case .saveWebhook(nil, _, _) = browser.pendingMutation {
                true
            } else {
                false
            }
            header(
                "Webhooks", add: integrations.canCreateWebhook ? "Add Webhook…" : nil, adding: adding,
                action: { edit(nil) }
            )
        }
    }

    private func trailing(for webhook: ConversationWebhook) -> some View {
        HStack(spacing: 8) {
            if let copy, copy.webhook == webhook.id {
                switch copy.phase {
                case .copying:
                    ProgressView().controlSize(.small)
                    Text("Copying…").foregroundStyle(.secondary)
                case .copied:
                    Label("Copied", systemImage: IntegrationSymbols.copied).foregroundStyle(.secondary)
                case .failed:
                    EmptyView()
                }
            }
            if isPending(webhook) {
                ProgressView().controlSize(.small)
            }
            if canCopyWebhookURL || !webhook.allowedActions.isDisjoint(with: [
                "editWebhook",
                "deleteWebhook"
            ]) {
                RowActionsMenu(name: webhook.name) { webhookMenu(webhook) }
            }
        }
        .font(.subheadline)
    }

    /// The editor shows its own refusal; an earlier one here is done with.
    private func edit(_ webhook: ConversationWebhook?) {
        lastSent = nil
        editing = WebhookEditing(webhook: webhook)
    }

    private func isPending(_ webhook: ConversationWebhook) -> Bool {
        switch browser.pendingMutation {
        case let .deleteWebhook(id): id == webhook.id
        case let .saveWebhook(id, _, _): id == webhook.id
        default: false
        }
    }

    // MARK: Copy URL

    /// Asks for the address and writes it to the pasteboard when it comes.
    /// The answer may never come: another copy, or the panel moving on,
    /// cancels this one. The row's state then clears on its own (`settle`).
    private func copyURL(of webhook: ConversationWebhook) {
        let request = WebhookCopy(webhook: webhook.id)
        lastSent = nil
        copy = request
        actions.webhookURL(webhook.id) { result in
            guard copy == request else { return }
            switch result {
            case let .success(url):
                // A credential: marked so clipboard managers leave it out of their history.
                copy?.phase = TextPasteboard.copy(url.absoluteString, concealed: true)
                    ? .copied : .failed("The URL couldn’t be copied. Try again.")
            case let .failure(error):
                copy?.phase = .failed(WebhookCopy.message(for: error))
            }
        }
    }

    /// Clears a finished copy's note after a moment, and gives up on an
    /// answer that hasn't come.
    private func settle(_ current: WebhookCopy?) async {
        guard let current else { return }
        let wait: Duration = switch current.phase {
        case .copying: .seconds(15)
        case .copied: .seconds(2)
        case .failed: .zero
        }
        guard wait > .zero else { return }
        try? await Task.sleep(for: wait)
        guard !Task.isCancelled, copy == current else { return }
        if current.phase == .copying {
            copy?.phase = .failed("The URL didn’t arrive. Try again.")
        } else {
            copy = nil
        }
    }
}

extension ConversationIntegrationsForm {
    private var canCopyWebhookURL: Bool {
        !details.allowedActions.isDisjoint(with: ["createWebhook", "editWebhook", "deleteWebhook"])
    }

    @ViewBuilder private func webhookMenu(_ webhook: ConversationWebhook) -> some View {
        if canCopyWebhookURL {
            Button("Copy URL", systemImage: DirectoryMenuSymbols.copy) { copyURL(of: webhook) }
                .disabled(busy)
        }
        if webhook.allowedActions.contains("editWebhook") {
            Button("Edit…", systemImage: IntegrationSymbols.edit) { edit(webhook) }
                .disabled(busy)
        }
        if webhook.allowedActions.contains("deleteWebhook") {
            Divider()
            Button("Delete…", systemImage: IntegrationSymbols.delete, role: .destructive) {
                confirming = .deleteWebhook(webhook)
            }
            .disabled(busy)
        }
    }
}
