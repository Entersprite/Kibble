import ChatKit
import SwiftUI

public enum UnreadFilter: String, Hashable, Sendable {
    case all
    case badgeOnly
}

public struct UnreadScene: Equatable, Sendable {
    public var showing = false
    public var filter: UnreadFilter = .badgeOnly
    public var messages: [Message]?
    public var readOnThisDevice: [Message] = []
    public var conversationsWithUnread: Set<Conversation.ID> = []
    public var badgeConversations: Set<Conversation.ID> = []
    public var isLoading = false
    public var historyFailed = false

    public init() {}

    public func shows(_ message: Message, in filter: UnreadFilter) -> Bool {
        filter == .all || (!message.isReply && badgeConversations.contains(message.conversationID))
    }

    func unreadConversations(in filter: UnreadFilter) -> Set<Conversation.ID> {
        filter == .badgeOnly ? badgeConversations : conversationsWithUnread
    }
}

public struct UnreadActions {
    public let show: () -> Void
    let retry: () -> Void
    public let setFilter: (UnreadFilter) -> Void
    let markMessageRead: ((Message) -> Void)?
    let markRead: (([Message], Conversation.ID) -> Void)?
    public let markAllRead: ((UnreadFilter) -> Void)?

    public init(
        show: @escaping () -> Void, retry: @escaping () -> Void,
        setFilter: @escaping (UnreadFilter) -> Void = { _ in },
        markMessageRead: ((Message) -> Void)? = nil,
        markRead: (([Message], Conversation.ID) -> Void)? = nil,
        markAllRead: ((UnreadFilter) -> Void)? = nil
    ) {
        self.show = show
        self.retry = retry
        self.setFilter = setFilter
        self.markMessageRead = markMessageRead
        self.markRead = markRead
        self.markAllRead = markAllRead
    }
}

/// The Unread list, in the detail pane: a `List`, as the Mentions and Saved
/// lists are, with a section for each conversation. A click selects a row,
/// Return or a double-click shows the message in its conversation, and the
/// checkmark at the row's end marks that one message read. Which messages it
/// lists and Mark All as Read are the window's, in its toolbar
/// (`UnreadToolbar`).
struct UnreadPane: View {
    let state: ChatSceneState
    let actions: UnreadActions
    let open: ((MessageAddress) -> Void)?
    @State private var selection: MessageAddress?

    var body: some View {
        let groups = UnreadPresentation.groups(state)
        let retryFooter = UnreadPresentation.showsRetryFooter(state, groups: groups)
        List(selection: $selection) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.messages, id: \.unreadAddress) { message in
                        row(message)
                            .tag(MessageAddress(message))
                    }
                } header: {
                    header(group)
                } footer: {
                    if retryFooter, group.id == groups.last?.id {
                        footer
                    }
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .overlay {
            emptyState(UnreadPresentation.content(state, groups: groups))
        }
        .contextMenu(forSelectionType: MessageAddress.self) { addresses in
            if let message = message(selectedBy: addresses) {
                menu(for: message)
            }
        } primaryAction: { addresses in
            if let message = message(selectedBy: addresses), canOpen(message) {
                open?(MessageAddress(message))
            }
        }
        .onChange(of: state.unread.filter) { _, _ in selection = nil }
    }

    private func message(selectedBy addresses: Set<MessageAddress>) -> Message? {
        guard addresses.count == 1, let address = addresses.first else { return nil }
        return UnreadPresentation.messages(state).first { MessageAddress($0) == address }
    }

    private func canOpen(_ message: Message) -> Bool {
        open != nil && state.conversations.contains { $0.id == message.conversationID }
    }

    private func canMark(_ id: Conversation.ID) -> Bool {
        actions.markRead != nil && !state.receiptsWithheld.contains(id)
    }

    private func markConversationRead(_ id: Conversation.ID) {
        let listed = UnreadPresentation.messages(state).filter { $0.conversationID == id }
        let earlier = UnreadPresentation.readOnThisDevice(state).filter { $0.conversationID == id }
        actions.markRead?(listed + earlier, id)
    }

    /// Built when the menu opens, from the row it opens on.
    @ViewBuilder private func menu(for message: Message) -> some View {
        if canOpen(message) {
            Button(UnreadPresentation.openTitle, systemImage: "text.bubble") {
                open?(MessageAddress(message))
            }
        }
        if let markMessageRead = actions.markMessageRead {
            Button(UnreadPresentation.markMessageTitle, systemImage: UnreadPresentation.markSymbol) {
                markMessageRead(message)
            }
        }
        if canMark(message.conversationID) {
            Divider()
            Button("Mark Conversation as Read") { markConversationRead(message.conversationID) }
        }
    }

    /// The conversation's name and how many of its messages are listed. Its
    /// action is a small text button, as a section's own action is in a
    /// system list, so the names stay the loudest thing in the header.
    private func header(_ group: UnreadPresentation.Group) -> some View {
        HStack(spacing: 6) {
            Text(group.title)
                .lineLimit(1)
            Text("\(group.messages.count)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .accessibilityLabel("\(group.messages.count) unread")
            Spacer(minLength: 8)
            if canMark(group.id) {
                Button(UnreadPresentation.markConversationTitle) { markConversationRead(group.id) }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .accessibilityLabel("Mark \(group.title) as read")
            }
        }
    }

    /// The Mentions row's shape under a header that already says where: who
    /// on one line with the time at its end, then the message.
    private func row(_ message: Message) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(Display.name(of: message.sender, in: state.directory))
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if message.isReply {
                        Text("in a thread")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(Display.timestamp(of: message.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                Text(MentionHighlight.attributed(
                    UnreadPresentation.preview(of: message), mentions: message.mentions, me: state.me,
                    inOwnBubble: false
                ))
                .lineLimit(3)
            }
            .accessibilityElement(children: .combine)
            if let markMessageRead = actions.markMessageRead {
                Button { markMessageRead(message) } label: {
                    Label(UnreadPresentation.markMessageTitle, systemImage: UnreadPresentation.markSymbol)
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(UnreadPresentation.markMessageHelp)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Below the rows: some conversations listed theirs and others could
    /// not be checked.
    private var footer: some View {
        HStack(spacing: 8) {
            Text(UnreadPresentation.moreFailedText)
            Button("Try Again", action: actions.retry)
                .controlSize(.small)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private func emptyState(_ content: UnreadPresentation.Content) -> some View {
        switch content {
        case .rows:
            EmptyView()
        case .looking:
            ProgressView(UnreadPresentation.lookingText)
        case .failed:
            ContentUnavailableView {
                Label("Couldn’t Load Unread Messages", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Try Again", action: actions.retry)
            }
        case let .nothingBadged(others):
            ContentUnavailableView {
                Label("No Unread Messages", systemImage: SidebarPinned.unreadSymbol)
            } description: {
                Text(others
                    ? "Everything the badge counts is read. Other unread messages are under All."
                    : "Everything the badge counts is read.")
            } actions: {
                if others {
                    Button("Show All") { actions.setFilter(.all) }
                }
            }
        case .unavailable:
            ContentUnavailableView(
                "Unread Messages Aren’t Available", systemImage: SidebarPinned.unreadSymbol,
                description: Text("Open a conversation in the sidebar to read its new messages.")
            )
        case .caughtUp:
            ContentUnavailableView("You’re All Caught Up", systemImage: SidebarPinned.unreadSymbol)
        }
    }
}

private extension Message {
    var unreadAddress: MessageAddress {
        MessageAddress(self)
    }
}
