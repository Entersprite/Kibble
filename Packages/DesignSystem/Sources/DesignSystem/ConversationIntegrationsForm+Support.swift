import ChatKit
import SwiftUI

/// Where a refused integration change says so: under the app or webhook it
/// was for, or under the Apps header for an app being added.
enum IntegrationFailure: Equatable {
    case app(Member.ID)
    case webhook(String)
    case addingApp

    /// What the section draws, for where a refusal can land.
    struct Shown: Equatable {
        var apps: Set<Member.ID> = []
        var webhooks: Set<String> = []
        var appsSection = false

        init(apps: Set<Member.ID> = [], webhooks: Set<String> = [], appsSection: Bool = false) {
            self.apps = apps; self.webhooks = webhooks; self.appsSection = appsSection
        }

        init(_ integrations: ConversationIntegrations?, showsApps: Bool, showsWebhooks: Bool) {
            guard let integrations else { return }
            appsSection = showsApps
            apps = showsApps ? Set(integrations.apps.map(\.id)) : []
            webhooks = showsWebhooks ? Set(integrations.webhooks.map(\.id)) : []
        }
    }

    /// The place for the refusal of `sent`, the last change this section
    /// sent: once nothing is on its way and the panel has an error, and only
    /// where that place is drawn, so the sheet's header shows any error
    /// that has nowhere here to go. Other changes (a webhook's save) say so
    /// in their own sheet.
    static func place(
        sent: ConversationMutation?, pending: ConversationMutation?, error: String?, shown: Shown
    ) -> Self? {
        guard error != nil, pending == nil, let sent else { return nil }
        switch sent {
        case let .removeApp(id): return shown.apps.contains(id) ? .app(id) : nil
        case let .deleteWebhook(id): return shown.webhooks.contains(id) ? .webhook(id) : nil
        case .addApp: return shown.appsSection ? .addingApp : nil
        default: return nil
        }
    }

    /// What tells the last change is done with: the write finishing, the
    /// error clearing, or the list reloading after a confirmed change.
    struct Progress: Equatable {
        var pending: ConversationMutation?
        var error: String?
        var integrations: ConversationIntegrations?
    }

    /// Whether the last change is done with: nothing on its way and no
    /// error, after a success or a reload. A later error is someone else's.
    static func forgetsSent(pending: ConversationMutation?, error: String?) -> Bool {
        pending == nil && error == nil
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
