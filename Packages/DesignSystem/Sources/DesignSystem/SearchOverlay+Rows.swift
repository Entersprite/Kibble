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

    // MARK: Selection: Spotlight-like — the top result, unless a row is picked

    /// On open: the hit Show All came back to, when it is listed.
    static func initialSelection(_ search: SearchSceneState) -> SearchRow? {
        guard let focus = search.focus else { return nil }
        let row = SearchRow.message(focus)
        return rows(search).contains(row) ? row : nil
    }

    /// What Return does: open the selected row, or the top row when nothing
    /// is selected yet (defensive — the overlay keeps a row selected whenever
    /// any are listed), or call `submit()` when there are none at all.
    enum ReturnAction: Equatable {
        case open(SearchRow)
        case submit
    }

    static func returnAction(selected: SearchRow?, rows: [SearchRow]) -> ReturnAction {
        guard !rows.isEmpty else { return .submit }
        return .open(selected ?? rows[0])
    }

    /// What the field takes when the model's query text changes: `nil` when
    /// it is what this field last sent, else the model's text, which a person
    /// row, Show All or ⌘F set without typing (search fix wave, finding 1).
    static func adopted(_ modelText: String, sent: String) -> String? {
        modelText == sent ? nil : modelText
    }

    /// The row at the end of the Messages section: a spinner while a page is
    /// out, a retry after one failed, else the trigger for the next page.
    /// The trigger is removed while a page is out, so it appears again, and
    /// asks again, after a page that was ignored (search fix wave, finding 6).
    enum More: Equatable {
        case loading
        case retry
        case trigger
    }

    static func more(_ search: SearchSceneState) -> More? {
        if search.isLoadingMore {
            return .loading
        }
        if search.loadMoreFailed {
            return .retry
        }
        return search.hasMore ? .trigger : nil
    }

    /// After the rows change (typing, results arriving, a filter): an explicit
    /// pick (↑↓ or hover, since the last keystroke) while its row is still
    /// listed, else the top row — Spotlight's "Return opens the top result".
    static func selected(previous: SearchRow?, explicit: Bool, in rows: [SearchRow]) -> SearchRow? {
        if explicit, let previous, rows.contains(previous) {
            return previous
        }
        return rows.first
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

/// The panel's fixed pieces, here so `SearchOverlay.swift` stays in lint's limit.
extension SearchOverlay {
    func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
    }

    func header(_ title: String, trailing: String? = nil, loading: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if loading {
                ProgressView().controlSize(.mini)
                Text("Searching…").font(.caption).foregroundStyle(.tertiary)
            } else if let trailing {
                Text(trailing).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 4)
        // VoiceOver's headings rotor moves from section to section.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    var footer: some View {
        HStack(spacing: 14) {
            Hint(keys: "↑↓", label: "Select")
            Hint(keys: "↩", label: "Open")
            Hint(keys: "esc", label: "Close")
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }
}

/// The panel's size in the window (the mockup's): at most 680 pt wide and
/// 560 tall, with 40 pt each side and 60 below kept clear.
enum SearchOverlayLayout {
    static let topInset: CGFloat = 24
    static let panelShape = RoundedRectangle(cornerRadius: 22)

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
        case .directMessage: "Direct Message"
        case .groupDirectMessage: "Group Chat"
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
            Avatar(member: other, directory: directory, size: 28).besideName()
        } else {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.22))
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: conversation.kind == .space ? "number" : "person.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                // The row names its kind in words.
                .accessibilityHidden(true)
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
            Avatar(member: person.id, directory: directory, size: 28).besideName()
            VStack(alignment: .leading, spacing: 1) {
                Text(SearchPresentation.highlighted(name, words: words))
                Text(person.email ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let messagesFrom {
                Button("Messages From", action: messagesFrom)
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
            Avatar(member: message.sender, directory: directory, size: 28).besideName()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Display.name(of: message.sender, in: directory)).fontWeight(.semibold)
                    if let conversationTitle {
                        Text("in \(conversationTitle)").foregroundStyle(.secondary)
                    }
                    if message.isReply {
                        Label("Thread Reply", systemImage: "arrowshape.turn.up.left")
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
