import ChatKit
import SwiftUI

/// The overlay's rows in keyboard order (search spec §1.2).
enum SearchRow: Hashable {
    case recent(String)
    case conversation(Conversation.ID)
    case person(Member.ID)
    case message(Message.ID)
}

enum SearchRows {
    static func rows(_ search: SearchSceneState) -> [SearchRow] {
        if showsRecents(search) {
            return search.recents.map(SearchRow.recent)
        }
        return search.conversations.map { .conversation($0.id) } + search.people.map { .person($0.id) }
            + search.hits.map { .message($0.id) }
    }

    /// No words and no filters: the recent searches, not the sections.
    static func showsRecents(_ search: SearchSceneState) -> Bool {
        search.query.text.trimmingCharacters(in: .whitespaces).isEmpty && !search.query.hasFilters
    }

    /// Whether the query reaches the message search at all: a filter, or two
    /// characters (the model's floor). Below it the Messages section says nothing.
    static func searchesMessages(_ query: MessageSearchQuery) -> Bool {
        query.hasFilters || query.text.trimmingCharacters(in: .whitespaces).count >= 2
    }

    // MARK: Selection: nothing until the person picks a row, so Return searches

    /// On open: the hit Show All came back to, when it is listed.
    static func initialSelection(_ search: SearchSceneState) -> SearchRow? {
        guard let focus = search.focus else { return nil }
        let row = SearchRow.message(focus)
        return rows(search).contains(row) ? row : nil
    }

    /// After the rows change without typing (hits arriving, a filter): the pick
    /// while its row is still listed, else nothing.
    static func kept(_ selected: SearchRow?, in rows: [SearchRow]) -> SearchRow? {
        guard let selected, rows.contains(selected) else { return nil }
        return selected
    }

    /// ↑ and ↓: from nothing, ↓ picks the first row and ↑ the last; from a row,
    /// a step that stops at either end.
    static func next(after rows: [SearchRow], selected: SearchRow?, by step: Int) -> SearchRow? {
        guard !rows.isEmpty else { return nil }
        guard let selected, let index = rows.firstIndex(of: selected) else {
            return step > 0 ? rows.first : rows.last
        }
        return rows[max(0, min(rows.count - 1, index + step))]
    }
}

/// The panel's size in the window (the mockup's): at most 680 pt wide and
/// 560 tall, with 40 pt each side and 60 below kept clear.
enum SearchOverlayLayout {
    static let topInset: CGFloat = 24

    static func panelWidth(for width: CGFloat) -> CGFloat {
        max(0, min(680, width - 80))
    }

    static func panelMaxHeight(for height: CGFloat) -> CGFloat {
        max(0, min(560, height - 60))
    }
}

struct ConversationHit: View {
    let conversation: Conversation
    let directory: [Member.ID: Member]
    let me: Member.ID?
    let words: [String]

    var body: some View {
        HStack(spacing: 10) {
            ConversationIcon(conversation: conversation, directory: directory, me: me)
            VStack(alignment: .leading, spacing: 1) {
                Text(SearchPresentation.highlighted(
                    Display.title(of: conversation, directory: directory, me: me),
                    words: words
                ))
                Text(kind).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var kind: String {
        switch conversation.kind {
        case .space:
            Display.memberCountLabel(of: conversation).map { "Space · \($0)" } ?? "Space"
        case .directMessage: "Direct message"
        case .groupDirectMessage: "Group chat"
        default: "Conversation"
        }
    }
}

struct ConversationIcon: View {
    let conversation: Conversation
    let directory: [Member.ID: Member]
    let me: Member.ID?

    var body: some View {
        if conversation.kind == .directMessage, let other = conversation.members.first(where: { $0 != me }) {
            Avatar(member: other, directory: directory, size: 28)
        } else {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.22))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: conversation.kind == .space ? "number" : "person.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
        }
    }
}

struct PersonHit: View {
    let person: Member
    let directory: [Member.ID: Member]
    let words: [String]
    /// `nil` when the backend cannot filter by sender: no button.
    let messagesFrom: (() -> Void)?

    /// A hit from the directory search may not be in `directory` yet, so its
    /// own name comes first.
    private var name: String {
        person.displayName ?? Display.name(of: person.id, in: directory)
    }

    var body: some View {
        HStack(spacing: 10) {
            Avatar(member: person.id, directory: directory, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(SearchPresentation.highlighted(name, words: words))
                Text(person.email ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let messagesFrom {
                Button("Messages from", action: messagesFrom)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
        }
    }
}

struct MessageHit: View {
    let message: Message
    let directory: [Member.ID: Member]
    /// The conversation's title, or `nil` when it is not in the sidebar.
    let conversationTitle: String?
    let words: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(member: message.sender, directory: directory, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Display.name(of: message.sender, in: directory)).fontWeight(.semibold)
                    if let conversationTitle {
                        Text("in \(conversationTitle)").foregroundStyle(.secondary)
                    }
                    if message.isReply {
                        Label("Thread reply", systemImage: "arrowshape.turn.up.left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                    Spacer()
                    Text(SearchPresentation.shortDate(message.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Text(SearchPresentation.highlighted(
                    SearchPresentation.snippet(message.text, words: words),
                    words: words
                ))
                .font(.callout)
                .lineLimit(2)
                .foregroundStyle(.primary.opacity(0.85))
            }
        }
    }
}
