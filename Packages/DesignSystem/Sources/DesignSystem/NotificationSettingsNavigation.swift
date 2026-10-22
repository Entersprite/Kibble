import ChatKit
import SwiftUI

/// Pane-local destinations never contribute navigation items to the Settings toolbar.
enum NotificationSettingsPage: Hashable {
    case section(SectionKey)
    case conversations
    case conversation(Conversation.ID)

    var parentTitle: String {
        switch self {
        case .section, .conversations: "Notifications"
        case .conversation: "Conversations"
        }
    }

    func title(in state: NotificationSettingsState) -> String {
        switch self {
        case let .section(section): Display.title(of: section)
        case .conversations: "Conversations"
        case let .conversation(id):
            state.conversations.first { $0.id == id }?.title ?? "Conversation"
        }
    }
}

enum NotificationSettingsFocus: Hashable {
    case back(NotificationSettingsPage)
    case link(NotificationSettingsPage)
}

struct NotificationPageHeader: View {
    let page: NotificationSettingsPage
    let title: String
    let focus: FocusState<NotificationSettingsFocus?>.Binding
    let back: () -> Void

    var body: some View {
        SettingsScopeHeader(showsNavigation: true) {
            Button(action: back) {
                Label(page.parentTitle, systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Back to \(page.parentTitle)")
            .focused(focus, equals: .back(page))
        } trailing: {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .help(title)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// A fresh pane/account owns a fresh scope, even if it opens the same page.
struct NotificationSettingsBackAction: Equatable {
    let scope: UUID
    let path: [NotificationSettingsPage]
    let perform: @MainActor () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope && lhs.path == rhs.path
    }
}

extension FocusedValues {
    @Entry var notificationSettingsBack: NotificationSettingsBackAction?
}

/// The native menu bar owns the shortcut; hidden parent pages register none.
public struct NotificationSettingsCommands: Commands {
    @FocusedValue(\.notificationSettingsBack) private var back

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Back", systemImage: "chevron.left") { back?.perform() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(back == nil)
        }
    }
}

struct NotificationPageLink: View {
    let title: String
    let summary: String
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack {
                LabeledContent(title) { Text(summary).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// Retain the parent's Form and its scroll position while a child is visible.
    func notificationPage(isActive: Bool) -> some View {
        opacity(isActive ? 1 : 0)
            .disabled(!isActive)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .zIndex(isActive ? 1 : 0)
    }
}
