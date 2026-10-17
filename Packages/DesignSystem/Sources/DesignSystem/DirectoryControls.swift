import ChatKit
import SwiftUI

/// A person as every people list draws one: face, name, and the address that
/// tells two people with one name apart.
struct PersonRow<Trailing: View>: View {
    let person: Member
    var size: CGFloat = 28
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Avatar(member: person.id, directory: [person.id: person], size: size)
            VStack(alignment: .leading, spacing: 1) {
                Text(PersonName.of(person)).lineLimit(1)
                if let email = person.email, email != person.displayName {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .contentShape(Rectangle())
    }
}

/// A person's name as a list shows it: their name, else their address.
enum PersonName {
    static func of(_ person: Member) -> String {
        person.displayName ?? person.email ?? "Unknown Person"
    }
}

extension PersonRow where Trailing == EmptyView {
    init(person: Member, size: CGFloat = 28) {
        self.init(person: person, size: size) { EmptyView() }
    }
}

/// A conversation's picture where it stands for the whole conversation: the
/// other person for a DM, a rounded square for a space (the shape spaces have
/// in every directory), and the group cluster for a group chat.
struct ConversationPicture: View {
    let conversation: Conversation
    var directory: [Member.ID: Member] = [:]
    var me: Member.ID?
    var size: CGFloat = 36

    var body: some View {
        switch conversation.kind {
        case .directMessage, .appDirectMessage:
            if let other = conversation.members.first(where: { $0 != me }) {
                Avatar(member: other, directory: directory, size: size)
            } else {
                UnknownPersonGlyph(size: size)
            }
        case .meetChat:
            MeetingPicture(size: size)
        case .groupDirectMessage:
            MonogramCircle(size: size) {
                Image(systemName: "person.3.fill").font(.system(size: size * 0.38))
            }
        default:
            spaceTile
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
    }

    private var spaceTile: some View {
        Group {
            if let url = conversation.avatarURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    monogram
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }

    private var monogram: some View {
        shape
            .fill(Color.accentColor.opacity(0.16))
            .overlay {
                Text(String((conversation.title ?? "#").prefix(1)).uppercased())
                    .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tint)
            }
    }
}

/// What a sort reads as in a menu: the order a person sees, not the
/// direction of a comparison.
enum SidebarSortTitles {
    static func sort(_ sort: SidebarSortOrder) -> String {
        sort == .name ? "Name" : "Recent Activity"
    }

    static func order(_ sort: SidebarSortOrder, ascending: Bool) -> String {
        if sort == .name {
            return ascending ? "A to Z" : "Z to A"
        }
        return ascending ? "Oldest First" : "Newest First"
    }

    /// A new sort starts in its own natural order (newest first, A to Z), so
    /// switching from "Newest First" to Name does not land on Z to A.
    static func changing(
        _ section: SidebarSectionPreference,
        to sort: SidebarSortOrder
    ) -> SidebarSectionPreference {
        var changed = section
        if changed.sort != sort {
            changed.sort = sort
            changed.isAscending = nil
        }
        return changed
    }
}

/// Sort By and Order, as the inline checkmarked items of a menu.
struct SidebarSortMenuItems: View {
    let section: SidebarSectionPreference
    let change: (SidebarSectionPreference) -> Void

    var body: some View {
        Section("Sort By") {
            Picker("Sort By", selection: Binding(
                get: { section.sort },
                set: { change(SidebarSortTitles.changing(section, to: $0)) }
            )) {
                ForEach([SidebarSortOrder.activity, .name], id: \.self) {
                    Text(SidebarSortTitles.sort($0)).tag($0)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Section("Order") {
            Picker("Order", selection: Binding(
                get: { section.sortsAscending },
                set: { var changed = section; changed.isAscending = $0; change(changed) }
            )) {
                ForEach([false, true], id: \.self) { ascending in
                    Text(SidebarSortTitles.order(section.sort, ascending: ascending)).tag(ascending)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

extension SidebarPreferences {
    func section(_ id: String) -> SidebarSectionPreference {
        orderedSections.first { $0.id == id } ?? SidebarSectionPreference(id: id)
    }

    func updating(_ section: SidebarSectionPreference) -> SidebarPreferences {
        var next = self
        next.update(section)
        return next
    }
}

/// A row whose secondary controls show only while it is hovered or selected,
/// as list rows on the Mac keep their action buttons out of sight.
struct DirectoryRow<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering || isSelected)
            .padding(.vertical, DirectoryLayout.rowPadding)
            .padding(.horizontal, 4)
            .onHover { hovering = $0 }
    }
}

/// The directory lists' shared measures: roomier than a sidebar, like the
/// rows of Mail's message list.
enum DirectoryLayout {
    static let pictureSize: CGFloat = 36
    static let rowPadding: CGFloat = 6
}

/// A list's heading, large and in the primary color, as the browse pages of
/// Music and the App Store head theirs. A row rather than a section header,
/// which the Mac underlines with a rule; untagged, so it is never selected.
struct DirectorySectionHeader: View {
    let title: String

    static func count(_ count: Int, _ noun: (singular: String, plural: String)) -> String {
        "\(count) \(count == 1 ? noun.singular : noun.plural)"
    }

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .listRowSeparator(.hidden)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A conversation in a full list: bigger than a sidebar row, with what kind
/// it is and when it last moved, the way Mail and Messages list them.
struct DirectoryConversationRow: View {
    let row: ConversationItemRowState
    let directory: [Member.ID: Member]
    let me: Member.ID?

    init(item: SidebarItem, state: ChatSceneState) {
        row = ConversationItemRowState(item: item, scene: state)
        me = state.me
        directory = RowDirectory.avatars(row.conversation.members, in: state.directory)
    }

    var body: some View {
        HStack(spacing: 12) {
            ConversationPicture(
                conversation: row.conversation, directory: directory, me: me,
                size: DirectoryLayout.pictureSize
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .fontWeight(row.showsUnread ? .semibold : .medium)
                    .lineLimit(1)
                if let detail = row.detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let date = row.lastActivity {
                Text(SearchPresentation.shortDate(date))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            Circle().fill(.tint).frame(width: 8, height: 8)
                .opacity(row.showsUnread ? 1 : 0)
                .accessibilityLabel("Unread")
                .accessibilityHidden(!row.showsUnread)
        }
        .padding(.vertical, DirectoryLayout.rowPadding)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .opacity(row.dimmed ? 0.55 : 1)
    }
}

struct DirectoryLoadingRow: View {
    var body: some View {
        HStack {
            Spacer()
            ProgressView().controlSize(.small)
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

struct DirectoryErrorRow: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).foregroundStyle(.secondary)
            Spacer()
            Button("Try Again", action: retry).controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}
