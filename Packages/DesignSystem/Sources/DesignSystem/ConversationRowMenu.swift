import ChatKit
import SwiftUI

/// Only the row's offered items and callbacks, so the menu closure does
/// not retain a sidebar snapshot containing the transcript and directory.
/// A meeting series row's items can act on several original chats.
struct ConversationRowMenu: View {
    let entries: [ConversationMenu.Entry]
    let actions: ChatSceneActions

    init(id: Conversation.ID, items: [ConversationMenu.Item], actions: ChatSceneActions) {
        self.init(entries: items.map { ConversationMenu.Entry(item: $0, targets: [id]) }, actions: actions)
    }

    init(entries: [ConversationMenu.Entry], actions: ChatSceneActions) {
        self.entries = entries
        self.actions = actions
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
    }
}
