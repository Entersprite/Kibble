import ChatKit
import SwiftUI

/// A sidebar row's menu: only the offered items and callbacks, resolved for
/// the clicked row when the menu opens (`ConversationMenu.rowMenu`). A meeting
/// series row's items can act on several original chats.
struct ConversationRowMenu: View {
    let entries: [ConversationMenu.Entry]
    let actions: ChatSceneActions
    let preferences: SidebarPreferences
    let favoriteTarget: SidebarSelection?

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
            let item = entry.item
            switch item {
            case .call:
                Button(item.title, systemImage: item.symbol) { entry.targets.forEach { actions.call?($0) } }
                if entry != entries.last {
                    Divider()
                }
            case let .action(action):
                Button(item.title, systemImage: item.symbol) {
                    for id in entry.targets {
                        actions.conversationActions?.perform(action, id)
                    }
                }
            case .markAsRead:
                Button(item.title, systemImage: item.symbol) {
                    entry.targets.forEach { actions.markRead?($0) }
                }
                Divider()
            case .mute:
                Button(item.title, systemImage: item.symbol) { entry.targets.forEach { actions.mute?($0) } }
            case .unmute:
                Button(item.title, systemImage: item.symbol) { entry.targets.forEach { actions.unmute?($0) } }
            case .notificationSettings:
                Button(item.title, systemImage: item.symbol) {
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
