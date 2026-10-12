import ChatKit
import SwiftUI

/// Only the row's offered items and callbacks, so the menu closure does
/// not retain a sidebar snapshot containing the transcript and directory.
struct ConversationRowMenu: View {
    let id: Conversation.ID
    let items: [ConversationMenu.Item]
    let actions: ChatSceneActions

    var body: some View {
        ForEach(items, id: \.self) { item in
            switch item {
            case let .action(action):
                Button(action.menuTitle) { actions.conversationActions?.perform(action, id) }
            case .markAsRead:
                Button("Mark as Read") { actions.markRead?(id) }
                Divider()
            case .mute:
                Button("Mute") { actions.mute?(id) }
            case .unmute:
                Button("Unmute") { actions.unmute?(id) }
            case .notificationSettings:
                Button("Notification Settings…") { actions.showNotificationSettings?(id) }
            }
        }
    }
}
