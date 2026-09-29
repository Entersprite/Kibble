import ChatKit
import SwiftUI

/// One row of the Mentions pane (the mentions-list spec §4). Values only:
/// the mapping from a stored mention is this initialiser, pure, and tested.
public struct MentionItem: Identifiable, Sendable, Equatable {
    public let id: Message.ID
    public let conversationID: Conversation.ID
    public let conversationTitle: String
    public let senderName: String
    public let createdAt: Date
    public let text: String
    public let mentions: [Mention]
    public let isUnread: Bool

    public init(
        message: Message, conversation: Conversation, isUnread: Bool,
        directory: [Member.ID: Member], me: Member.ID?
    ) {
        id = message.id
        conversationID = conversation.id
        conversationTitle = Display.title(of: conversation, directory: directory, me: me)
        senderName = Display.name(of: message.sender, in: directory)
        createdAt = message.createdAt
        text = message.text
        mentions = message.mentions
        self.isUnread = isUnread
    }
}

/// The backfill's status as the pane draws it. It mirrors SyncEngine's
/// `MentionBackfillStatus`, which this package cannot see (ruling 2).
public struct MentionsStatus: Sendable, Equatable {
    public var running: Bool
    public var failedConversations: Int

    public init(running: Bool = false, failedConversations: Int = 0) {
        self.running = running
        self.failedConversations = failedConversations
    }
}

/// What the row and the pane say. Pure, so every state is a test.
public enum MentionsPresentation {
    public enum Content: Equatable, Sendable {
        case looking
        case empty
        case items
    }

    public static let lookingText = "Looking for mentions…"
    public static let emptyText = "No mentions in the last 30 days"

    /// The plain count, and no badge at zero (ruling 13).
    public static func badge(unread: Int) -> String? {
        unread > 0 ? "\(unread)" : nil
    }

    /// "Looking" only while a run is going *and* nothing is listed yet.
    /// Stored mentions show while a run refreshes them.
    public static func content(items: [MentionItem], status: MentionsStatus) -> Content {
        if !items.isEmpty {
            return .items
        }
        return status.running ? .looking : .empty
    }

    public static func footer(_ status: MentionsStatus) -> String? {
        switch status.failedConversations {
        case ...0: nil
        case 1: "Couldn't check 1 conversation"
        case let count: "Couldn't check \(count) conversations"
        }
    }
}

/// The Mentions list, in the detail pane. A `ScrollView` of a `LazyVStack`,
/// not a `List`, so that the list itself can be rendered headless
/// (`MentionsPaneList`, ruling 17). It never sees a store: values in,
/// `open` out.
public struct MentionsPane: View {
    let items: [MentionItem]
    let status: MentionsStatus
    let me: Member.ID?
    let open: (Conversation.ID, Message.ID) -> Void

    public init(
        items: [MentionItem], status: MentionsStatus, me: Member.ID?,
        open: @escaping (Conversation.ID, Message.ID) -> Void
    ) {
        self.items = items
        self.status = status
        self.me = me
        self.open = open
    }

    public var body: some View {
        ScrollView {
            MentionsPaneList(items: items, status: status, me: me, open: open)
        }
        .overlay {
            switch MentionsPresentation.content(items: items, status: status) {
            case .looking:
                ProgressView(MentionsPresentation.lookingText)
            case .empty:
                ContentUnavailableView(MentionsPresentation.emptyText, systemImage: "at")
            case .items:
                EmptyView()
            }
        }
    }
}

/// The items and the footer, as plain stacks.
struct MentionsPaneList: View {
    let items: [MentionItem]
    let status: MentionsStatus
    let me: Member.ID?
    let open: (Conversation.ID, Message.ID) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                MentionItemRow(item: item, me: me, open: open)
            }
            if let footer = MentionsPresentation.footer(status) {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
        }
        .padding(12)
    }
}

/// One mention. The title, sender and time use `Display`, and the text uses
/// `MentionHighlight` as it is drawn in anyone else's bubble. It is
/// semibold while unread.
struct MentionItemRow: View {
    let item: MentionItem
    let me: Member.ID?
    let open: (Conversation.ID, Message.ID) -> Void

    var body: some View {
        Button {
            open(item.conversationID, item.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.conversationTitle)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(item.senderName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Display.timestamp(of: item.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(MentionHighlight.attributed(
                    item.text, mentions: item.mentions, me: me, inOwnBubble: false
                ))
                .lineLimit(3)
                // `nil`, not `.regular`, while read: a `.regular` weight
                // overrides the span's own semibold, and the render check
                // showed `@all` drawn regular because of it.
                .fontWeight(item.isUnread ? .semibold : nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
