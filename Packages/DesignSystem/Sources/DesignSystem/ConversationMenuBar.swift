import ChatKit
import SwiftUI

/// The menu bar's Conversation menu: which items it draws, which of them are
/// enabled, and what each acts on.
///
/// Pure, built from the window's own state and actions, so a test can read
/// it. An item is drawn only where the host supplied its action (never a
/// control the seam cannot honor) and is enabled only where the window
/// offers the same thing now: Show Details and Call as the toolbar does,
/// Mark as Read, Mute and Notification Settings… as the sidebar row's menu
/// does (`ConversationMenu`), Follow and Close as the thread column does.
/// Built with no state, for when the main window is not in front, every
/// drawn item is disabled and no conversation is listed.
public struct ConversationMenuBar: Equatable {
    /// What choosing an item does. Each carries the target it was enabled
    /// for, so the menu acts on what it showed.
    public enum Command: Hashable, Sendable {
        case details(Conversation.ID)
        case call(Conversation.ID)
        case videoCall(Conversation.ID)
        case joinCall(Conversation.ID)
        case returnToCall
        case markAsRead([Conversation.ID])
        case mute([Conversation.ID])
        case unmute([Conversation.ID])
        case notificationSettings(Conversation.ID)
        case setFollowed(Bool)
        case closeThread
        case mentions
        case threads
        case calls
        case select(SidebarSelection)
    }

    /// How an item is drawn: a command with its symbol, or a checkmark item,
    /// as Follow Thread and the listed conversations are.
    public enum Style: Hashable, Sendable {
        case button(symbol: String)
        case checkmark(isOn: Bool)
    }

    public struct Entry: Hashable, Identifiable, Sendable {
        /// Stable across updates: the item's slot, not its title.
        public let id: String
        public let title: String
        public let style: Style
        public let shortcut: KeyboardShortcut?
        /// `nil` disables the item.
        public let command: Command?

        public var isEnabled: Bool {
            command != nil
        }
    }

    /// Whose window it was built for; a different account's is a different menu.
    public let account: String?
    /// The menu's sections, in order, none of them empty.
    public let sections: [[Entry]]

    @MainActor
    public init(state: ChatSceneState?, actions: ChatSceneActions) {
        account = state?.accountID
        let order = state.map { Self.visibleOrder($0, actions: actions) } ?? []
        sections = [
            Self.conversationEntries(state, actions: actions),
            Self.ruleEntries(state, actions: actions),
            Self.threadEntries(state, actions: actions),
            Self.paneEntries(state, actions: actions),
            Self.stepEntries(state, order: order),
            Self.listedEntries(state, order: order)
        ].filter { !$0.isEmpty }
    }

    /// The rows down the sidebar a person can select, in order: sections
    /// that are collapsed hold none, and a conversation listed twice (in
    /// Favorites and in its own section) counts once, where it first appears.
    /// Meeting series count only where the host can select one.
    @MainActor
    static func visibleOrder(_ state: ChatSceneState, actions: ChatSceneActions) -> [SidebarItem] {
        let collapsed = actions.setSectionCollapsed == nil ? [] : state.collapsedSections
        var seen = Set<SidebarSelection>()
        return SidebarProjection.build(
            state.conversations, preferences: state.sidebarPreferences, directory: state.directory,
            me: state.me
        )
        .filter { !collapsed.contains($0.id) }
        .flatMap(\.items)
        .filter { item in
            if case .meeting = item, actions.selectMeetingSeries == nil {
                return false
            }
            return seen.insert(item.id).inserted
        }
    }

    /// The item after or before the sidebar's selection: from no selection
    /// (or Mentions, Threads, or a conversation the sidebar does not list),
    /// Next starts at the top and Previous at the bottom. Neither wraps.
    static func neighbor(
        of selection: SidebarSelection?,
        in order: [SidebarItem],
        step: Int
    ) -> SidebarItem? {
        guard let index = order.firstIndex(where: { $0.id == selection }) else {
            return step > 0 ? order.first : order.last
        }
        let next = index + step
        return order.indices.contains(next) ? order[next] : nil
    }
}

extension ConversationMenuBar {
    /// Show Details, Call and Video Call, each where the toolbar draws its
    /// button: details for a group or space while no directory page is open,
    /// calls for a DM the call service can reach.
    @MainActor
    private static func conversationEntries(_ state: ChatSceneState?, actions: ChatSceneActions) -> [Entry] {
        let conversation = state?.selectedConversation
        var entries: [Entry] = []
        // A backend that cannot read details gets no item, where the window
        // can say so; without the window, its host's browser decides.
        if actions.browser != nil, state?.capabilities.canReadConversationDetails != false {
            let shows = conversation.map { $0.kind != .directMessage } == true && state?.browser.page == nil
            entries.append(Entry(
                id: "details", title: "Show Details", style: .button(symbol: "info.circle"), shortcut: nil,
                command: shows ? conversation.map { .details($0.id) } : nil
            ))
        }
        let offer = state.flatMap { state in
            state.selectedConversation.flatMap { conversation in
                callOffer(in: state, actions: actions).map { (conversation.id, $0) }
            }
        }
        let callable = offer.flatMap { $0.1 == .call ? $0.0 : nil }
        if actions.call != nil {
            entries.append(Entry(
                id: "call", title: ConversationMenu.Item.call.title,
                style: .button(symbol: ConversationMenu.Item.call.symbol), shortcut: nil,
                command: callable.map(Command.call)
            ))
            if actions.videoCall != nil {
                entries.append(Entry(
                    id: "videoCall", title: "Video Call", style: .button(symbol: "video"), shortcut: nil,
                    command: callable.map(Command.videoCall)
                ))
            }
        }
        if actions.joinCall != nil {
            let joinable = offer.flatMap {
                if case .join = $0.1 {
                    $0.0
                } else {
                    nil
                }
            }
            entries.append(Entry(
                id: "joinCall", title: "Join Call", style: .button(symbol: "phone.arrow.up.right"),
                shortcut: nil, command: joinable.map(Command.joinCall)
            ))
        }
        if actions.returnToCall != nil {
            entries.append(Entry(
                id: "returnToCall", title: "Return to Call", style: .button(symbol: "phone.fill"),
                shortcut: nil, command: offer?.1 == .returnToCall ? .returnToCall : nil
            ))
        }
        return entries
    }

    /// What the toolbar offers for the conversation on screen, each choice
    /// falling back to Call where the host supplied nothing to carry it out
    /// (Call itself raises a call already going on).
    @MainActor
    static func callOffer(in state: ChatSceneState, actions: ChatSceneActions) -> ConversationCallOffer? {
        guard !state.showingMentions, !state.threads.showingList,
              let conversation = state.selectedConversation else { return nil }
        let callable = actions.call != nil && state.callableConversations.contains(conversation.id)
        switch state.callOffer {
        case .returnToCall? where actions.returnToCall != nil: return .returnToCall
        case let .join(participants)? where actions.joinCall != nil: return .join(participants: participants)
        default: return callable ? .call : nil
        }
    }

    /// Mark as Read, Mute or Unmute, and Notification Settings…, from the
    /// row menu's own rules for the selected row: the same items, for the
    /// same conversations, a right-click on it would offer.
    @MainActor
    private static func ruleEntries(_ state: ChatSceneState?, actions: ChatSceneActions) -> [Entry] {
        let offers = ConversationMenu.Offers(actions)
        let rowEntries = state.map { rowMenuEntries(for: $0, offers: offers) } ?? []
        let target = { (item: ConversationMenu.Item) in rowEntries.first { $0.item == item }?.targets }
        var entries: [Entry] = []
        if offers.markRead {
            entries.append(Entry(
                id: "markAsRead", title: ConversationMenu.Item.markAsRead.title,
                style: .button(symbol: ConversationMenu.Item.markAsRead.symbol),
                shortcut: MenuBarShortcuts.markAsRead, command: target(.markAsRead).map(Command.markAsRead)
            ))
        }
        if offers.mute || offers.unmute {
            let unmute = target(.unmute)
            let item: ConversationMenu.Item = unmute == nil ? .mute : .unmute
            entries.append(Entry(
                id: "mute", title: item.title, style: .button(symbol: item.symbol), shortcut: nil,
                command: unmute.map(Command.unmute) ?? target(.mute).map(Command.mute)
            ))
        }
        if offers.notificationSettings {
            let item = ConversationMenu.Item.notificationSettings
            entries.append(Entry(
                id: "notificationSettings", title: item.title, style: .button(symbol: item.symbol),
                shortcut: nil, command: target(item)?.first.map(Command.notificationSettings)
            ))
        }
        return entries
    }

    /// The row menu's entries for the sidebar's selection: a conversation's
    /// own, or a meeting series' across its chats.
    private static func rowMenuEntries(
        for state: ChatSceneState, offers: ConversationMenu.Offers
    ) -> [ConversationMenu.Entry] {
        switch state.sidebarSelection {
        case let .conversation(id)?:
            guard let conversation = state.conversations.first(where: { $0.id == id }) else { return [] }
            return ConversationMenu.items(for: conversation, state: state, offers: offers).map {
                ConversationMenu.Entry(item: $0, targets: [id])
            }
        case .meetingSeries?:
            return state.meetingSeries
                .map { ConversationMenu.entries(for: $0, state: state, offers: offers) } ?? []
        case .mentions?, .threads?, .calls?, nil:
            return []
        }
    }

    /// Follow Thread, checked while followed, and Close Thread, while the
    /// thread column is open. Follow waits for a change on its way, as the
    /// column's own button does.
    @MainActor
    private static func threadEntries(_ state: ChatSceneState?, actions: ChatSceneActions) -> [Entry] {
        guard actions.threads != nil else { return [] }
        let panel = state.flatMap(openThread)
        let followed = panel?.thread.isFollowed ?? false
        return [
            Entry(
                id: "follow", title: "Follow Thread", style: .checkmark(isOn: followed), shortcut: nil,
                command: panel.flatMap { $0.followPending ? nil : .setFollowed(!followed) }
            ),
            Entry(
                id: "closeThread", title: "Close Thread",
                style: .button(symbol: ThreadsPresentation.closeSymbol),
                shortcut: nil, command: panel == nil ? nil : .closeThread
            )
        ]
    }

    /// The thread the window's thread column shows: its conversation on
    /// screen, one with replies, and a thread open in it.
    private static func openThread(_ state: ChatSceneState) -> ThreadPanelState? {
        guard !state.showingMentions, !state.threads.showingList,
              ThreadsPresentation.offersReplies(in: state.selectedConversation)
        else { return nil }
        return state.threads.panel
    }

    /// Go to Mentions, Go to Threads and Go to Calls, the sidebar's pinned rows.
    @MainActor
    private static func paneEntries(_ state: ChatSceneState?, actions: ChatSceneActions) -> [Entry] {
        var entries: [Entry] = []
        if actions.showMentions != nil {
            entries.append(Entry(
                id: "mentions", title: "Go to Mentions", style: .button(symbol: SidebarPinned.mentionsSymbol),
                shortcut: nil, command: state == nil ? nil : .mentions
            ))
        }
        if actions.threads != nil {
            entries.append(Entry(
                id: "threads", title: "Go to Threads", style: .button(symbol: ThreadsPresentation.rowSymbol),
                shortcut: nil, command: state == nil ? nil : .threads
            ))
        }
        if actions.callHistory != nil {
            entries.append(Entry(
                id: "calls", title: "Go to Calls", style: .button(symbol: CallHistoryPresentation.rowSymbol),
                shortcut: nil, command: state == nil ? nil : .calls
            ))
        }
        return entries
    }

    private static func stepEntries(_ state: ChatSceneState?, order: [SidebarItem]) -> [Entry] {
        let selection = state?.sidebarSelection
        let next = neighbor(of: selection, in: order, step: 1)
        let previous = neighbor(of: selection, in: order, step: -1)
        return [
            Entry(
                id: "next", title: "Next Conversation", style: .button(symbol: "chevron.down"),
                shortcut: MenuBarShortcuts.nextConversation, command: next.map { .select($0.id) }
            ),
            Entry(
                id: "previous", title: "Previous Conversation", style: .button(symbol: "chevron.up"),
                shortcut: MenuBarShortcuts.previousConversation, command: previous.map { .select($0.id) }
            )
        ]
    }

    /// The first nine rows down the sidebar on Command-1 to Command-9, the
    /// selected one checked, as the Accounts menu lists accounts.
    private static func listedEntries(_ state: ChatSceneState?, order: [SidebarItem]) -> [Entry] {
        guard let state else { return [] }
        return order.prefix(9).enumerated().map { index, item in
            Entry(
                id: "listed.\(index)", title: item.title(directory: state.directory, me: state.me),
                style: .checkmark(isOn: item.id == state.sidebarSelection),
                shortcut: MenuBarShortcuts.conversation(index), command: .select(item.id)
            )
        }
    }
}

public extension ConversationMenuBar {
    /// Carries out a command through the window's own actions, the way the
    /// window's control for it would.
    @MainActor
    static func perform(_ command: Command, actions: ChatSceneActions) {
        switch command {
        case let .details(id): actions.browser?.details(id, false)
        case let .call(id): actions.call?(id)
        case let .videoCall(id): actions.videoCall?(id)
        case let .joinCall(id): actions.joinCall?(id)
        case .returnToCall: actions.returnToCall?()
        case let .markAsRead(ids): ids.forEach { actions.markRead?($0) }
        case let .mute(ids): ids.forEach { actions.mute?($0) }
        case let .unmute(ids): ids.forEach { actions.unmute?($0) }
        case let .notificationSettings(id): actions.showNotificationSettings?(id)
        case .setFollowed, .closeThread, .mentions, .threads, .calls, .select: move(command, actions: actions)
        }
    }

    /// The commands that change what the window shows rather than act on a
    /// conversation.
    @MainActor
    private static func move(_ command: Command, actions: ChatSceneActions) {
        switch command {
        case let .setFollowed(followed): actions.threads?.setFollowed(followed)
        case .closeThread: actions.threads?.close()
        case .mentions: actions.showMentions?()
        case .threads: actions.threads?.showList()
        case .calls: actions.callHistory?.show()
        case let .select(selection): SidebarPinned.choose(selection, actions: actions)
        case .details, .call, .videoCall, .joinCall, .returnToCall, .markAsRead, .mute, .unmute,
             .notificationSettings: break
        }
    }
}
