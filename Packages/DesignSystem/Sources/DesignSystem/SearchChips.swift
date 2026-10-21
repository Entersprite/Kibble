import ChatKit
import SwiftUI

/// The Date chip's choices: Google Chat's "Older than…" (findings.md §65.5).
enum DateChoice: CaseIterable {
    case any, olderThanAWeek, olderThanAMonth, olderThanAYear

    var title: String {
        switch self {
        case .any: "Any time"
        case .olderThanAWeek: "Older than a week"
        case .olderThanAMonth: "Older than a month"
        case .olderThanAYear: "Older than a year"
        }
    }

    func bound(now: Date) -> Date? {
        switch self {
        case .any: nil
        case .olderThanAWeek: now.addingTimeInterval(-7 * 86400)
        case .olderThanAMonth: now.addingTimeInterval(-30 * 86400)
        case .olderThanAYear: now.addingTimeInterval(-365 * 86400)
        }
    }
}

/// The overlay's filter chips, as Google Chat's. A chip shows only when the
/// backend honors its filter (`Capabilities.messageSearchFilters`), and the
/// sort menu only when it can sort newest first.
struct SearchFilterRow: View {
    let query: MessageSearchQuery
    let filters: Set<MessageSearchFilter>
    let people: [Member]
    let conversations: [Conversation]
    let directory: [Member.ID: Member]
    let me: Member.ID?
    let setQuery: (MessageSearchQuery) -> Void

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
                    dateChip
                }
                if filters.contains(.newerThan) {
                    newerDateChip
                }
                if filters.contains(.hasFile) || filters.contains(.hasLink) {
                    hasChip
                }
                if filters.contains(.mentionsMe) {
                    Button { change { $0.mentionsMe.toggle() } } label: {
                        Chip(title: "Mentions me", icon: "at", active: query.mentionsMe, menu: false)
                    }
                    .buttonStyle(.plain)
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
            Button("Anyone") { change { $0.from = nil } }
            Divider()
            ForEach(people, id: \.id) { person in
                Button(Display.name(of: person.id, in: directory)) { change { $0.from = person.id } }
            }
        } label: {
            Chip(
                title: query.from.map { "From: \(Display.name(of: $0, in: directory))" } ?? "From",
                icon: "person",
                active: query.from != nil
            )
        }
        .chipMenu()
    }

    private var conversationChip: some View {
        Menu {
            Button("Anywhere") { change { $0.conversation = nil } }
            Divider()
            ForEach(conversations, id: \.id) { conversation in
                Button(Display.title(of: conversation, directory: directory, me: me)) {
                    change { $0.conversation = conversation.id }
                }
            }
        } label: {
            Chip(
                title: conversationTitle,
                icon: "bubble.left.and.bubble.right",
                active: query.conversation != nil
            )
        }
        .chipMenu()
    }

    private var conversationTitle: String {
        guard let id = query.conversation else { return "Said in" }
        guard let conversation = conversations.first(where: { $0.id == id })
        else { return "In a conversation" }
        return "In: \(Display.title(of: conversation, directory: directory, me: me))"
    }

    /// "Now" is read when a choice is clicked, never while the menu is built
    /// (CLAUDE.md: a menu's contents are built with the view).
    private var dateChip: some View {
        Menu {
            ForEach(DateChoice.allCases, id: \.self) { choice in
                Button(choice.title) { change { $0.olderThan = choice.bound(now: .now) } }
            }
        } label: {
            Chip(
                title: query.olderThan.map { "Before \($0.formatted(.dateTime.month(.abbreviated).day()))" }
                    ?? "Date",
                icon: "calendar",
                active: query.olderThan != nil
            )
        }
        .chipMenu()
    }

    private var newerDateChip: some View {
        Menu {
            Button("Any time") { change { $0.newerThan = nil } }
            Button("Past day") { change { $0.newerThan = Date.now.addingTimeInterval(-86400) } }
            Button("Past week") { change { $0.newerThan = Date.now.addingTimeInterval(-604_800) } }
            Button("Past month") { change { $0.newerThan = Date.now.addingTimeInterval(-2_592_000) } }
            Button("Past year") { change { $0.newerThan = Date.now.addingTimeInterval(-31_536_000) } }
        } label: {
            Chip(
                title: query.newerThan.map { "After \($0.formatted(.dateTime.month(.abbreviated).day()))" }
                    ?? "After",
                icon: "calendar", active: query.newerThan != nil
            )
        }
        .chipMenu()
    }

    private var hasChip: some View {
        Menu {
            Button("Anything") { change { $0.hasFile = false; $0.hasLink = false } }
            if filters.contains(.hasFile) {
                Button("File") { change { $0.hasFile = true; $0.hasLink = false } }
            }
            if filters.contains(.hasLink) {
                Button("Link") { change { $0.hasFile = false; $0.hasLink = true } }
            }
        } label: {
            Chip(title: hasTitle, icon: "paperclip", active: query.hasFile || query.hasLink)
        }
        .chipMenu()
    }

    private var hasTitle: String {
        switch (query.hasFile, query.hasLink) {
        case (true, true): "Has file and link"
        case (true, false): "Has file"
        case (false, true): "Has link"
        case (false, false): "Has"
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: Binding(
                get: { query.order == .newest ? MessageSearchOrder.newest : .relevance },
                set: { order in change { $0.order = order } }
            )) {
                Text("Most relevant").tag(MessageSearchOrder.relevance)
                Text("Most recent").tag(MessageSearchOrder.newest)
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Text(query.order == .newest ? "Most recent" : "Most relevant")
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .chipMenu()
    }
}

private extension View {
    func chipMenu() -> some View {
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

struct Chip: View {
    let title: String
    let icon: String
    let active: Bool
    var menu = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption)
            Text(title).lineLimit(1)
            if menu {
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(active ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.07)))
        .foregroundStyle(active ? Color.accentColor : Color.primary)
        .contentShape(Capsule())
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
