import ChatKit
import SwiftUI

/// What the Unread pane and its toolbar say and list. Pure, so every state
/// is a test, and a plain type, so a test may call it off the main actor.
enum UnreadPresentation {
    static let openTitle = MentionsPresentation.openTitle
    static let markMessageTitle = "Mark as Read"
    static let markMessageHelp = "Mark this message as read on this Mac"
    static let markConversationTitle = "Mark as Read"
    static let markAllTitle = "Mark All as Read"
    static let markSymbol = "checkmark.circle"
    static let lookingText = "Looking for unread messages…"
    static let moreFailedText = "Couldn’t check every conversation."

    static func title(of filter: UnreadFilter) -> String {
        switch filter {
        case .all: "All"
        case .badgeOnly: "Badge Only"
        }
    }

    static func help(for filter: UnreadFilter) -> String {
        switch filter {
        case .all: "Showing every unread message, with thread replies"
        case .badgeOnly: "Showing the unread messages the app’s badge counts"
        }
    }

    /// One conversation's unread messages, under its name.
    struct Group: Identifiable, Equatable {
        let id: Conversation.ID
        let title: String
        let messages: [Message]
    }

    /// What the pane draws where it has no rows.
    enum Content: Equatable {
        case rows
        case looking
        case failed
        /// Nothing the badge counts is unread. `others` says the All filter
        /// has something, so the pane can offer it.
        case nothingBadged(others: Bool)
        /// Conversations count unread messages that could not be listed.
        case unavailable
        case caughtUp
    }

    static func messages(_ state: ChatSceneState) -> [Message] {
        state.unread.messages?.filter { state.unread.shows($0, in: state.unread.filter) } ?? []
    }

    /// The rows already marked read on this device that the filter covers. A
    /// conversation's read takes them along.
    static func readOnThisDevice(_ state: ChatSceneState) -> [Message] {
        state.unread.readOnThisDevice.filter { state.unread.shows($0, in: state.unread.filter) }
    }

    /// By conversation name, so a new arrival never moves the row under the
    /// pointer to another place in the list.
    static func groups(_ state: ChatSceneState) -> [Group] {
        let conversations = Dictionary(
            state.conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        return Dictionary(grouping: messages(state), by: \.conversationID)
            .compactMap { id, messages -> Group? in
                guard let conversation = conversations[id] else { return nil }
                return Group(
                    id: id, title: Display.title(of: conversation, directory: state.directory, me: state.me),
                    messages: messages
                )
            }
            .sorted { lhs, rhs in
                let order = lhs.title.localizedStandardCompare(rhs.title)
                return order == .orderedSame ? lhs.id.rawValue < rhs.id.rawValue : order == .orderedAscending
            }
    }

    static func content(_ state: ChatSceneState, groups: [Group]) -> Content {
        let unread = state.unread
        if !groups.isEmpty {
            return .rows
        }
        if unread.filter == .badgeOnly, unread.badgeConversations.isEmpty {
            let listed = unread.messages?.isEmpty == false
            return .nothingBadged(others: listed || !unread.conversationsWithUnread.isEmpty)
        }
        if unread.historyFailed, !unread.isLoading {
            return .failed
        }
        if unread.messages == nil || unread.isLoading {
            return .looking
        }
        if readOnThisDevice(state).isEmpty, !unread.unreadConversations(in: unread.filter).isEmpty {
            return .unavailable
        }
        return .caughtUp
    }

    /// A check that failed for some conversations while others listed theirs.
    static func showsRetryFooter(_ state: ChatSceneState, groups: [Group]) -> Bool {
        !groups.isEmpty && state.unread.historyFailed && !state.unread.isLoading
    }

    static func canMarkAll(_ state: ChatSceneState) -> Bool {
        !messages(state).isEmpty || !readOnThisDevice(state).isEmpty ||
            !state.unread.unreadConversations(in: state.unread.filter).isEmpty
    }

    /// A message with no words is named by what it carries.
    static func preview(of message: Message) -> String {
        if !message.text.isEmpty {
            return message.text
        }
        if let attachment = message.attachments.first {
            return attachment.name.isEmpty ? "Attachment" : attachment.name
        }
        return message.callStatus == nil ? "Message" : "Call"
    }
}

/// The Unread pane's part of the window toolbar: which unread messages it
/// lists, and the one action on all of them. They are the window's controls
/// for its content, so they sit in the toolbar and not in a strip above the
/// list. Mark All as Read dims when nothing is left; it is drawn only where
/// the host offers it.
struct UnreadToolbar: ToolbarContent {
    let state: ChatSceneState
    let actions: UnreadActions

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("Show", selection: Binding(get: { state.unread.filter }, set: actions.setFilter)) {
                Text(UnreadPresentation.title(of: .all)).tag(UnreadFilter.all)
                Text(UnreadPresentation.title(of: .badgeOnly)).tag(UnreadFilter.badgeOnly)
            }
            .pickerStyle(.segmented)
            .help(UnreadPresentation.help(for: state.unread.filter))
        }
        if let markAllRead = actions.markAllRead {
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .primaryAction) {
                Button(UnreadPresentation.markAllTitle, systemImage: UnreadPresentation.markSymbol) {
                    markAllRead(state.unread.filter)
                }
                .labelStyle(.titleOnly)
                .disabled(!UnreadPresentation.canMarkAll(state))
                .help("Mark every message listed here as read")
            }
        }
    }
}
