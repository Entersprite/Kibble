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

    var body: some View {
        HStack(spacing: 10) {
            Avatar(member: person.id, directory: directory, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(SearchPresentation.highlighted(person.displayName ?? person.id.rawValue, words: words))
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
