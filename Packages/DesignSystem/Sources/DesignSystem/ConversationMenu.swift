import ChatKit

/// What a sidebar row's context menu offers, and in what order.
///
/// Pure and apart from the view so a test can read it: this is where "never
/// draw a control the seam cannot honour" is enforced for the row menu, and
/// nowhere else checks it. `ConversationList` draws exactly these items.
enum ConversationMenu {
    enum Item: Hashable {
        case info
        case call
        case markAsRead
        case action(ConversationAction)
        case mute
        case unmute
        case notificationSettings
    }

    /// Which of the menu's actions the host supplied - `ChatSceneActions`'
    /// optional closures, as presence only.
    struct Offers: Equatable {
        var call = false
        var markRead = false
        var mute = false
        var unmute = false
        var notificationSettings = false
        var info = false
        var moveToSection = false
        var conversationActions: Capabilities = .init()
    }

    /// Info leads, where the host can show it and the backend can read details.
    /// Then Call, for a DM the header would offer it for. Then Mark as Read
    /// where it can publish, Mute or Unmute by the conversation's own record,
    /// then its editor - each only where the host offered it.
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
        let actions: [ConversationAction] = [.markUnread, .leave, .hide, .block, .delete]
        for action in actions
            where offers.conversationActions.supports(action) && action.isAvailable(for: conversation.kind) {
            if action == .markUnread {
                items.insert(.action(action), at: 0)
            } else {
                items.append(.action(action))
            }
        }
        // A group or space the call service can call starts its call quietly.
        if offers.call, state.callableConversations.contains(id) {
            items.insert(.call, at: 0)
        }
        if offers.info, state.capabilities.canReadConversationDetails {
            items.insert(.info, at: 0)
        }
        return items
    }
}

extension ConversationMenu {
    /// One menu item and the original chats it acts on.
    struct Entry: Hashable {
        let item: Item
        let targets: [Conversation.ID]
    }

    /// A series with one original offers that chat's own menu. Across several,
    /// Mark as Read reads each unread original that may publish, and Mute or
    /// Unmute applies to all of them, by the same records the row's own menu
    /// reads. One chat's notification editor is not offered for several.
    static func entries(for series: MeetingSeries, state: ChatSceneState, offers: Offers) -> [Entry] {
        let originals = series.occurrences
        guard originals.count > 1 else {
            return items(for: series.latest, state: state, offers: offers).map {
                Entry(item: $0, targets: [series.latest.id])
            }
        }
        var entries: [Entry] = []
        let unread = originals.filter { $0.hasUnread && !state.receiptsWithheld.contains($0.id) }.map(\.id)
        if offers.markRead, !unread.isEmpty {
            entries.append(Entry(item: .markAsRead, targets: unread))
        }
        let unmuted = originals.map(\.id).filter { !state.muted.contains($0) }
        if unmuted.isEmpty {
            if offers.unmute {
                entries.append(Entry(item: .unmute, targets: originals.map(\.id)))
            }
        } else if offers.mute {
            entries.append(Entry(item: .mute, targets: unmuted))
        }
        if offers.info, state.capabilities.canReadConversationDetails {
            entries.insert(Entry(item: .info, targets: [series.latest.id]), at: 0)
        }
        return entries
    }
}

extension ConversationMenu.Item {
    var title: String {
        switch self {
        case .info: "Info…"
        case .call: "Call"
        case .markAsRead: "Mark as Read"
        case let .action(action): action.menuTitle
        case .mute: "Mute"
        case .unmute: "Unmute"
        case .notificationSettings: "Notification Settings…"
        }
    }

    /// Checked to exist by `SidebarSymbolTests`: a wrong name compiles and
    /// draws nothing.
    var symbol: String {
        switch self {
        case .info: DirectoryMenuSymbols.details
        case .call: "phone"
        case .markAsRead: "envelope.open"
        case let .action(action): action.menuSymbol
        case .mute: "bell.slash"
        case .unmute: "bell"
        case .notificationSettings: "bell.badge"
        }
    }
}

extension ConversationMenu {
    /// A right-click's menu, resolved when the menu opens: the entries for
    /// the clicked row, what Favorites adds or removes, and the name a
    /// confirmation asks about.
    struct RowMenu: Equatable {
        let entries: [Entry]
        let favorite: SidebarSelection
        let title: String
        var section: ConversationSectionMenu?
    }

    /// The menu for the rows a right-click names, from the sections the list
    /// drew and the state it drew them with: never a read of anything else.
    /// One row, since the sidebar selects one; a click on empty space or on
    /// several rows has no menu, as does a row the sections no longer hold.
    static func rowMenu(
        for clicked: Set<SidebarSelection>, in sections: [SidebarSection], state: ChatSceneState,
        offers: Offers
    ) -> RowMenu? {
        guard clicked.count == 1, let target = clicked.first else { return nil }
        let item = sections.lazy.flatMap(\.items).first { $0.id == target }
        switch item {
        case let .conversation(conversation)?:
            return RowMenu(
                entries: items(for: conversation, state: state, offers: offers).map {
                    Entry(item: $0, targets: [conversation.id])
                },
                favorite: target,
                title: Display.title(of: conversation, directory: state.directory, me: state.me),
                section: sectionMenu(for: conversation.id, state: state, offers: offers)
            )
        case let .meeting(series)?:
            return RowMenu(
                entries: entries(for: series, state: state, offers: offers), favorite: target,
                title: series.title,
                section: series.occurrences.count == 1
                    ? sectionMenu(for: series.latest.id, state: state, offers: offers) : nil
            )
        case nil:
            return nil
        }
    }

    private static func sectionMenu(
        for id: Conversation.ID, state: ChatSceneState, offers: Offers
    ) -> ConversationSectionMenu? {
        guard offers.moveToSection else { return nil }
        return ConversationSectionMenu(conversationID: id, sections: state.conversationSections)
    }
}

@MainActor
extension ConversationMenu.Offers {
    init(_ actions: ChatSceneActions) {
        self.init(
            call: actions.call != nil,
            markRead: actions.markRead != nil,
            mute: actions.mute != nil,
            unmute: actions.unmute != nil,
            notificationSettings: actions.showNotificationSettings != nil,
            info: actions.browser != nil,
            moveToSection: actions.moveConversationToSection != nil,
            conversationActions: actions.conversationActions?.capabilities ?? Capabilities()
        )
    }
}
