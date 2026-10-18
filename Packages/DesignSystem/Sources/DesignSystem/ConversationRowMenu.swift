import ChatKit
import SwiftUI

/// Only the row's offered items and callbacks, so the menu closure does
/// not retain a sidebar snapshot containing the transcript and directory.
/// A meeting series row's items can act on several original chats.
struct ConversationRowMenu: View {
    let entries: [ConversationMenu.Entry]
    let actions: ChatSceneActions
    let preferences: SidebarPreferences
    let favoriteTarget: SidebarSelection?

    init(
        id: Conversation.ID, items: [ConversationMenu.Item], preferences: SidebarPreferences,
        actions: ChatSceneActions
    ) {
        self.init(
            entries: items.map { ConversationMenu.Entry(item: $0, targets: [id]) },
            favoriteTarget: .conversation(id), preferences: preferences, actions: actions
        )
    }

    init(
        entries: [ConversationMenu.Entry], favoriteTarget: SidebarSelection,
        preferences: SidebarPreferences, actions: ChatSceneActions
    ) {
        self.entries = entries
        self.actions = actions
        self.preferences = preferences
        self.favoriteTarget = favoriteTarget
    }

    var body: some View {
        ForEach(entries, id: \.self) { entry in
            switch entry.item {
            case .call:
                Button("Call") { entry.targets.forEach { actions.call?($0) } }
                if entry != entries.last {
                    Divider()
                }
            case let .action(action):
                Button(action.menuTitle) {
                    for id in entry.targets {
                        actions.conversationActions?.perform(action, id)
                    }
                }
            case .markAsRead:
                Button("Mark as Read") { entry.targets.forEach { actions.markRead?($0) } }
                Divider()
            case .mute:
                Button("Mute") { entry.targets.forEach { actions.mute?($0) } }
            case .unmute:
                Button("Unmute") { entry.targets.forEach { actions.unmute?($0) } }
            case .notificationSettings:
                Button("Notification Settings…") {
                    entry.targets.forEach { actions.showNotificationSettings?($0) }
                }
            }
        }
        if let favoriteTarget, let update = actions.updateSidebar {
            if !entries.isEmpty {
                Divider()
            }
            FavoriteMenuButton(target: favoriteTarget, preferences: preferences, update: update)
        }
    }
}
