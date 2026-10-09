import ChatKit
import SwiftUI

/// The Threads list, in the detail pane (threads spec §5.3): followed
/// threads, newest activity first. A `ScrollView` of a `LazyVStack`, not a
/// `List`, so the list renders headless (`MentionsPane`'s reasoning).
public struct ThreadsPane: View {
    let items: [ThreadListItem]
    let me: Member.ID?
    /// The window's directory, for the repliers' avatars, as the transcript's
    /// marks get it.
    let directory: [Member.ID: Member]
    let open: (Conversation.ID, MessageThread.ID) -> Void

    public init(
        items: [ThreadListItem], me: Member.ID?, directory: [Member.ID: Member],
        open: @escaping (Conversation.ID, MessageThread.ID) -> Void
    ) {
        self.items = items
        self.me = me
        self.directory = directory
        self.open = open
    }

    enum Content: Equatable {
        case empty
        case items
    }

    static func content(items: [ThreadListItem]) -> Content {
        items.isEmpty ? .empty : .items
    }

    public var body: some View {
        ScrollView {
            // Redrawn every minute, so a mark's "just now" moves on, as the
            // transcript's marks do (`ThreadMark`). `.now`, not the
            // timeline's date, so a redraw for any other reason draws now.
            TimelineView(.everyMinute) { _ in
                ThreadsPaneList(items: items, me: me, directory: directory, now: .now, open: open)
            }
        }
        .overlay {
            if Self.content(items: items) == .empty {
                ContentUnavailableView(
                    ThreadsPresentation.emptyText, systemImage: ThreadsPresentation.rowSymbol
                )
            }
        }
    }
}

/// The rows, as plain stacks.
struct ThreadsPaneList: View {
    let items: [ThreadListItem]
    let me: Member.ID?
    let directory: [Member.ID: Member]
    let now: Date
    let open: (Conversation.ID, MessageThread.ID) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                ThreadItemRow(item: item, me: me, directory: directory, now: now, open: open)
            }
        }
        .padding(12)
    }
}

/// One followed thread: where, who, when, the first message, and its mark.
///
/// The mark gets the window's directory, as the transcript's marks do, so a
/// replier is drawn by photo or initials; an empty one would draw every
/// replier as the unknown-person glyph (`Avatar`'s rungs).
struct ThreadItemRow: View {
    let item: ThreadListItem
    let me: Member.ID?
    let directory: [Member.ID: Member]
    let now: Date
    let open: (Conversation.ID, MessageThread.ID) -> Void

    var body: some View {
        Button {
            open(item.conversationID, item.thread.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.conversationTitle)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(item.senderName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Display.timestamp(of: item.thread.lastActivity ?? item.root.createdAt, now: now))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                rootText
                ThreadMarkLabel(thread: item.thread, directory: directory, now: now)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            [
                item.conversationTitle,
                item.senderName,
                spokenText,
                ThreadMarkText.spoken(item.thread, now: now)
            ]
            .joined(separator: ", ")
        )
    }

    /// A deleted first message keeps its row, so its replies stay reachable
    /// (Review Focus 1); the store has blanked its text, so it says so, as
    /// its bubble does.
    @ViewBuilder private var rootText: some View {
        if item.root.isDeleted {
            Text("Message deleted")
                .font(.callout.italic())
                .foregroundStyle(.tertiary)
        } else {
            Text(MentionHighlight.attributed(
                item.root.text, mentions: item.root.mentions, me: me, inOwnBubble: false
            ))
            .lineLimit(2)
            // `nil`, not `.regular`, while read (`MentionItemRow`'s reason).
            .fontWeight(item.thread.hasUnread ? .semibold : nil)
        }
    }

    private var spokenText: String {
        item.root.isDeleted ? "Message deleted" : item.root.text
    }
}
