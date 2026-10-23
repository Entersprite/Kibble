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

    @State private var addingApp = false
    @State private var editing: WebhookEditing?
    @State private var confirming: IntegrationConfirmation?
    @State private var copy: WebhookCopy?

    private var browser: ConversationBrowserScene {
        state.browser
    }

    /// `mutate` drops a write while one is on its way or the details need reloading.
    private var busy: Bool {
        browser.isSubmitting || browser.needsReconciliation || browser.isLoadingAllParticipants
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
        .sheet(isPresented: $addingApp) {
            AddAppSheet(conversationName: title, state: state, actions: actions)
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
            Button(confirmation.button, role: .destructive) { actions.mutate(confirmation.mutation) }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            if let message = confirmation.message {
                Text(message)
            }
        }
        .task(id: copy) { await settle(copy) }
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
            ForEach(integrations.apps) { app in
                AppRow(app: app) { trailing(for: app) }
                    .contextMenu { appMenu(app) }
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
                action: { addingApp = true }
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
            Button("Message", systemImage: DirectoryMenuSymbols.message) { actions.openApp(app.id) }
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
                action: { editing = WebhookEditing(webhook: nil) }
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
            RowActionsMenu(name: webhook.name) { webhookMenu(webhook) }
        }
        .font(.subheadline)
    }

    private func isPending(_ webhook: ConversationWebhook) -> Bool {
        switch browser.pendingMutation {
        case let .deleteWebhook(id): id == webhook.id
        case let .saveWebhook(id, _, _): id == webhook.id
        default: false
        }
    }

    @ViewBuilder private func webhookMenu(_ webhook: ConversationWebhook) -> some View {
        Button("Copy URL", systemImage: DirectoryMenuSymbols.copy) { copyURL(of: webhook) }
        if webhook.allowedActions.contains("editWebhook") {
            Button("Edit…", systemImage: IntegrationSymbols.edit) {
                editing = WebhookEditing(webhook: webhook)
            }
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

    // MARK: Copy URL

    /// Asks for the address and writes it to the pasteboard when it comes.
    /// The answer may never come: another copy, or the panel moving on,
    /// cancels this one. The row's state then clears on its own (`settle`).
    private func copyURL(of webhook: ConversationWebhook) {
        let request = WebhookCopy(webhook: webhook.id)
        copy = request
        actions.webhookURL(webhook.id) { result in
            guard copy == request else { return }
            switch result {
            case let .success(url):
                copy?.phase = TextPasteboard.copy(url.absoluteString)
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

/// A destructive integration change waiting on its alert.
enum IntegrationConfirmation: Equatable {
    case removeApp(ConversationApp)
    case deleteWebhook(ConversationWebhook)

    func title(in conversation: String) -> String {
        switch self {
        case let .removeApp(app): "Remove \(AppName.of(app)) from \(conversation)?"
        case let .deleteWebhook(webhook): "Delete the webhook “\(webhook.name)”?"
        }
    }

    var message: String? {
        switch self {
        case .removeApp: nil
        case .deleteWebhook: "Anything posting to its URL will stop working."
        }
    }

    var button: String {
        switch self {
        case .removeApp: "Remove"
        case .deleteWebhook: "Delete"
        }
    }

    var mutation: ConversationMutation {
        switch self {
        case let .removeApp(app): .removeApp(app.id)
        case let .deleteWebhook(webhook): .deleteWebhook(webhook.id)
        }
    }
}

/// A row's actions at its end, the same items as its context menu.
struct RowActionsMenu<Items: View>: View {
    let name: String
    @ViewBuilder var items: Items

    var body: some View {
        Menu {
            items
        } label: {
            Label("Actions for \(name)", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Actions")
    }
}

/// The Integrations menus' own symbols, checked as `DirectoryMenuSymbols` are.
enum IntegrationSymbols {
    static let webhook = "link"
    static let edit = "pencil"
    static let delete = "trash"
    static let copied = "checkmark"

    static let all = [webhook, edit, delete, copied]
}
