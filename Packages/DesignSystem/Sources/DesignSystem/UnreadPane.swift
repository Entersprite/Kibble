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

struct UnreadPane: View {
    let state: ChatSceneState
    let actions: UnreadActions
    let open: ((MessageAddress) -> Void)?
    @State private var selection: Message.ID?
    private var filter: UnreadFilter {
        state.unread.filter
    }

    private struct ConversationGroup: Identifiable {
        let id: Conversation.ID
        let title: String
        let messages: [Message]
    }

    var body: some View {
        let groups = groups
        let canMarkAll = actions.markAllRead != nil &&
            (!filteredMessages.isEmpty || !filteredIndividuallyRead.isEmpty ||
                !state.unread.unreadConversations(in: filter).isEmpty)
        VStack(spacing: 0) {
            controls(canMarkAll)
            Divider()
            if groups.isEmpty {
                empty
            } else {
                List(selection: $selection) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.messages, id: \.id) { message in
                                row(message)
                            }
                        } header: {
                            header(group)
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: Message.ID.self) { ids in
                    if let message = message(selectedBy: ids), let open {
                        Button(MentionsPresentation.openTitle) { open(MessageAddress(message)) }
                    }
                } primaryAction: { ids in
                    if let message = message(selectedBy: ids) {
                        open?(MessageAddress(message))
                    }
                }
            }
        }
        .onChange(of: filter) { _, _ in selection = nil }
    }

    private func message(selectedBy ids: Set<Message.ID>) -> Message? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return filteredMessages.first { $0.id == id }
    }

    private var groups: [ConversationGroup] {
        let conversations = Dictionary(uniqueKeysWithValues: state.conversations.map { ($0.id, $0) })
        let messages = Dictionary(grouping: filteredMessages, by: \.conversationID)
        return messages.compactMap { id, messages -> ConversationGroup? in
            guard let conversation = conversations[id] else { return nil }
            return ConversationGroup(
                id: id, title: Display.title(of: conversation, directory: state.directory, me: state.me),
                messages: messages
            )
        }.sorted { lhs, rhs in
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return order == .orderedSame ? lhs.id.rawValue < rhs.id.rawValue : order == .orderedAscending
        }
    }

    private func canMark(_ id: Conversation.ID) -> Bool {
        actions.markRead != nil && !state.receiptsWithheld.contains(id)
    }

    private var filteredMessages: [Message] {
        state.unread.messages?.filter { state.unread.shows($0, in: filter) } ?? []
    }

    private var filteredIndividuallyRead: [Message] {
        state.unread.readOnThisDevice.filter { state.unread.shows($0, in: filter) }
    }

    private func controls(_ canMarkAll: Bool) -> some View {
        HStack(spacing: 10) {
            Picker("Unread filter", selection: Binding(get: { filter }, set: actions.setFilter)) {
                Text("All").tag(UnreadFilter.all)
                Text("Badge Only").tag(UnreadFilter.badgeOnly)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            if state.unread.historyFailed, !state.unread.isLoading {
                Button("Try Again", action: actions.retry)
            }
            if canMarkAll {
                Button("Mark All as Read") { actions.markAllRead?(filter) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var empty: some View {
        Group {
            if filter == .badgeOnly, state.unread.badgeConversations.isEmpty {
                ContentUnavailableView("No Badge Unreads", systemImage: SidebarPinned.unreadSymbol)
            } else if state.unread.historyFailed, !state.unread.isLoading {
                ContentUnavailableView(
                    "Couldn’t Load Unread Messages", systemImage: SidebarPinned.unreadSymbol
                )
            } else if state.unread.messages == nil || state.unread.isLoading {
                ProgressView("Looking for unread messages…")
            } else if filteredIndividuallyRead.isEmpty,
                      !state.unread.unreadConversations(in: filter).isEmpty {
                ContentUnavailableView(
                    "Unread Messages Aren’t Available", systemImage: SidebarPinned.unreadSymbol
                )
            } else {
                ContentUnavailableView("You’re All Caught Up", systemImage: SidebarPinned.unreadSymbol)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ group: ConversationGroup) -> some View {
        HStack {
            Text(group.title)
            Text("\(group.messages.count)")
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(group.messages.count) unread")
            Spacer()
            if canMark(group.id) {
                Button("Mark as Read") {
                    let earlier = filteredIndividuallyRead.filter { $0.conversationID == group.id }
                    actions.markRead?(group.messages + earlier, group.id)
                }
                .accessibilityLabel("Mark \(group.title) as read")
            }
        }
    }

    private func row(_ message: Message) -> some View {
        HStack(spacing: 10) {
            messagePreview(message)
            if let markMessageRead = actions.markMessageRead {
                Button {
                    markMessageRead(message)
                } label: {
                    Label("Mark Message as Read", systemImage: "checkmark.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Mark this message as read on this Mac")
            }
        }
        .padding(.vertical, 4)
    }

    private func messagePreview(_ message: Message) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(Display.name(of: message.sender, in: state.directory))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if message.isReply {
                    Text("Thread reply").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(Display.timestamp(of: message.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .font(.callout)
            Text(MentionHighlight.attributed(
                preview(message), mentions: message.mentions, me: state.me, inOwnBubble: false
            ))
            .lineLimit(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func preview(_ message: Message) -> String {
        if !message.text.isEmpty {
            return message.text
        }
        if !message.attachments.isEmpty {
            return "Attachment"
        }
        if message.callStatus != nil {
            return "Call"
        }
        return "Message"
    }
}
