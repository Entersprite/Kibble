import ChatKit

/// What a sidebar row's context menu offers, and in what order.
///
/// Pure and apart from the view so a test can read it: this is where "never
/// draw a control the seam cannot honour" is enforced for the row menu, and
/// nowhere else checks it. `ConversationList` draws exactly these items.
enum ConversationMenu {
    enum Item: Hashable {
        case markAsRead
        case mute
        case unmute
        case notificationSettings
    }

    /// Which of the menu's actions the host supplied - `ChatSceneActions`'
    /// optional closures, as presence only.
    struct Offers: Equatable {
        var markRead = false
        var mute = false
        var unmute = false
        var notificationSettings = false
    }

    /// Mark as Read where it can publish, Mute or Unmute by the conversation's
    /// own record, then its editor - each only where the host offered it.
    ///
    /// `hasUnread`, not the drawn indicator: a muted conversation looks read
    /// and still is not, for its sender. Mute versus Unmute reads `muted`, the
    /// conversation's own record, never `dimmed`: a conversation silenced by
    /// its section or the Meet preset has nothing of its own to unmute
    /// (decision 1).
    static func items(for conversation: Conversation, state: ChatSceneState, offers: Offers) -> [Item] {
        let id = conversation.id
        var items: [Item] = []
        if conversation.hasUnread, !state.receiptsWithheld.contains(id), offers.markRead {
            items.append(.markAsRead)
        }
        if state.muted.contains(id) {
            if offers.unmute {
                items.append(.unmute)
            }
        } else if offers.mute {
            items.append(.mute)
        }
        if offers.notificationSettings {
            items.append(.notificationSettings)
        }
        return items
    }
}

extension ConversationMenu.Offers {
    @MainActor init(_ actions: ChatSceneActions) {
        self.init(
            markRead: actions.markRead != nil,
            mute: actions.mute != nil,
            unmute: actions.unmute != nil,
            notificationSettings: actions.showNotificationSettings != nil
        )
    }
}
