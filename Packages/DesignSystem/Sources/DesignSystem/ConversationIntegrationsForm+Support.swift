import ChatKit
import SwiftUI

/// Where a refused integration change says so: under the app or webhook it
/// was for, or under the Apps header for an app being added.
enum IntegrationFailure: Equatable {
    case app(Member.ID)
    case webhook(String)
    case addingApp

    /// The place for the refusal of `sent`, the last change this section
    /// sent: once nothing is on its way and the panel has an error. Other
    /// changes (a webhook's save) say so in their own sheet.
    static func place(
        sent: ConversationMutation?, pending: ConversationMutation?, error: String?
    ) -> Self? {
        guard error != nil, pending == nil, let sent else { return nil }
        switch sent {
        case let .removeApp(id): return .app(id)
        case let .deleteWebhook(id): return .webhook(id)
        case .addApp: return .addingApp
        default: return nil
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
