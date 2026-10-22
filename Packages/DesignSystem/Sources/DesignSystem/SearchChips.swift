import ChatKit
import SwiftUI

/// The Date chips' choices: Google Chat's "Older than…" (findings.md §65.5)
/// for the older bound, and "Past…" for the newer one.
enum DateChoice: CaseIterable {
    case any, day, week, month, year

    static let older: [DateChoice] = [.any, .week, .month, .year]
    static let newer: [DateChoice] = [.any, .day, .week, .month, .year]

    var olderTitle: String {
        switch self {
        case .any: "Any Time"
        case .day: "Older Than a Day"
        case .week: "Older Than a Week"
        case .month: "Older Than a Month"
        case .year: "Older Than a Year"
        }
    }

    var newerTitle: String {
        switch self {
        case .any: "Any Time"
        case .day: "Past Day"
        case .week: "Past Week"
        case .month: "Past Month"
        case .year: "Past Year"
        }
    }

    /// `now` less this span, or `nil` for any time.
    func bound(now: Date) -> Date? {
        switch self {
        case .any: nil
        case .day: now.addingTimeInterval(-86400)
        case .week: now.addingTimeInterval(-7 * 86400)
        case .month: now.addingTimeInterval(-30 * 86400)
        case .year: now.addingTimeInterval(-365 * 86400)
        }
    }
}

/// Which choice a Date chip's menu checks. The query keeps only the instant,
/// counted back from when the choice was made, and the menu never reads the
/// clock while it is built (CLAUDE.md: a menu's contents are built with the
/// view), so the chip remembers which choice gave which instant.
struct DatePick: Equatable {
    var choice: DateChoice
    var bound: Date?

    /// Any Time without a bound; the remembered choice when it made this
    /// bound; else nothing, for a bound set before this chip was drawn.
    static func checked(_ bound: Date?, remembered: DatePick?) -> DateChoice? {
        guard let bound else { return .any }
        return remembered?.bound == bound ? remembered?.choice : nil
    }
}

/// The Has chip's choices. Each is one filter on its own, as the chip sets them.
enum HasChoice: Hashable {
    case anything, file, link

    static func of(_ query: MessageSearchQuery) -> HasChoice? {
        switch (query.hasFile, query.hasLink) {
        case (false, false): .anything
        case (true, false): .file
        case (false, true): .link
        case (true, true): nil
        }
    }
}

/// The overlay's filter chips, as Google Chat's. A chip shows only when the
/// backend honors its filter (`Capabilities.messageSearchFilters`), and the
/// sort menu only when it can sort newest first.
///
/// Each chip is a small bordered capsule, tinted while its filter is on, and a
/// menu of checkmarked choices. Not glass: the chips sit in the glass panel,
/// and glass on glass is what the guidelines rule out.
struct SearchFilterRow: View {
    let query: MessageSearchQuery
    let filters: Set<MessageSearchFilter>
    let people: [Member]
    let conversations: [Conversation]
    let directory: [Member.ID: Member]
    let me: Member.ID?
    let setQuery: (MessageSearchQuery) -> Void
    @State private var olderPick: DatePick?
    @State private var newerPick: DatePick?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                if filters.contains(.from) {
                    fromChip
                }
                if filters.contains(.conversation) {
                    conversationChip
                }
                if filters.contains(.olderThan) {
                    olderChip
                }
                if filters.contains(.newerThan) {
                    newerChip
                }
                if filters.contains(.hasFile) || filters.contains(.hasLink) {
                    hasChip
                }
                if filters.contains(.mentionsMe) {
                    Toggle(isOn: Binding(
                        get: { query.mentionsMe },
                        set: { on in change { $0.mentionsMe = on } }
                    )) {
                        Label("Mentions Me", systemImage: "at")
                    }
                    .toggleStyle(.button)
                    .chip(active: query.mentionsMe)
                }
                Spacer(minLength: 8)
                if filters.contains(.newestFirst) {
                    sortMenu
                }
            }
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private func change(_ edit: (inout MessageSearchQuery) -> Void) {
        var next = query
        edit(&next)
        setQuery(next)
    }

    private var fromChip: some View {
        Menu {
            Picker("From", selection: Binding(
                get: { query.from },
                set: { person in change { $0.from = person } }
            )) {
                Text("Anyone").tag(Member.ID?.none)
                Divider()
                ForEach(people, id: \.id) { person in
                    Text(Display.name(of: person.id, in: directory)).tag(Member.ID?.some(person.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(
                query.from.map { "From: \(Display.name(of: $0, in: directory))" } ?? "From",
                systemImage: "person"
            )
        }
        .chip(active: query.from != nil)
    }

    private var conversationChip: some View {
        Menu {
            Picker("Said In", selection: Binding(
                get: { query.conversation },
                set: { conversation in change { $0.conversation = conversation } }
            )) {
                Text("Anywhere").tag(Conversation.ID?.none)
                Divider()
                ForEach(conversations, id: \.id) { conversation in
                    Text(Display.title(of: conversation, directory: directory, me: me))
                        .tag(Conversation.ID?.some(conversation.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(conversationTitle, systemImage: "bubble.left.and.bubble.right")
        }
        .chip(active: query.conversation != nil)
    }

    private var conversationTitle: String {
        guard let id = query.conversation else { return "Said In" }
        guard let conversation = conversations.first(where: { $0.id == id })
        else { return "In a Conversation" }
        return "In: \(Display.title(of: conversation, directory: directory, me: me))"
    }

    /// "Now" is read when a choice is made, never while the menu is built
    /// (CLAUDE.md: a menu's contents are built with the view).
    private var olderChip: some View {
        Menu {
            Picker("Date", selection: Binding(
                get: { DatePick.checked(query.olderThan, remembered: olderPick) },
                set: { choice in
                    guard let choice else { return }
                    let bound = choice.bound(now: .now)
                    olderPick = DatePick(choice: choice, bound: bound)
                    change { $0.olderThan = bound }
                }
            )) {
                ForEach(DateChoice.older, id: \.self) { Text($0.olderTitle).tag(DateChoice?.some($0)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(
                query.olderThan
                    .map { "Before \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? "Date",
                systemImage: "calendar"
            )
        }
        .chip(active: query.olderThan != nil)
    }

    private var newerChip: some View {
        Menu {
            Picker("After", selection: Binding(
                get: { DatePick.checked(query.newerThan, remembered: newerPick) },
                set: { choice in
                    guard let choice else { return }
                    let bound = choice.bound(now: .now)
                    newerPick = DatePick(choice: choice, bound: bound)
                    change { $0.newerThan = bound }
                }
            )) {
                ForEach(DateChoice.newer, id: \.self) { Text($0.newerTitle).tag(DateChoice?.some($0)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(
                query.newerThan
                    .map { "After \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? "After",
                systemImage: "calendar"
            )
        }
        .chip(active: query.newerThan != nil)
    }

    private var hasChip: some View {
        Menu {
            Picker("Has", selection: Binding(
                get: { HasChoice.of(query) },
                set: { choice in
                    change {
                        $0.hasFile = choice == .file
                        $0.hasLink = choice == .link
                    }
                }
            )) {
                Text("Anything").tag(HasChoice?.some(.anything))
                if filters.contains(.hasFile) {
                    Text("File").tag(HasChoice?.some(.file))
                }
                if filters.contains(.hasLink) {
                    Text("Link").tag(HasChoice?.some(.link))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(hasTitle, systemImage: "paperclip")
        }
        .chip(active: query.hasFile || query.hasLink)
    }

    private var hasTitle: String {
        switch (query.hasFile, query.hasLink) {
        case (true, true): "Has File and Link"
        case (true, false): "Has File"
        case (false, true): "Has Link"
        case (false, false): "Has"
        }
    }

    /// The order, not a filter: plain words and a chevron at the row's
    /// trailing edge. The chevron is part of the label, with the system's
    /// indicator hidden, so it shows wherever the words do: on the glass
    /// panel a borderless menu showed the words alone.
    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: Binding(
                get: { query.order == .newest ? MessageSearchOrder.newest : .relevance },
                set: { order in change { $0.order = order } }
            )) {
                Text("Most Relevant").tag(MessageSearchOrder.relevance)
                Text("Most Recent").tag(MessageSearchOrder.newest)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 3) {
                Text(query.order == .newest ? "Most Recent" : "Most Relevant")
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private extension View {
    /// A filter chip: a small bordered capsule, tinted while its filter is on.
    func chip(active: Bool) -> some View {
        menuStyle(.button)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(active ? .accentColor : nil)
            .fixedSize()
    }
}

/// A key and what it does, for the overlay's footer.
struct Hint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            Text(label).font(.caption)
        }
        .foregroundStyle(.secondary)
    }
}
