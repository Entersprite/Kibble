import SwiftUI

/// The Search row: opens the search overlay, as Edit › Search… (⌘F) does. A
/// button rather than a selectable row, because search is an overlay over the
/// window and nothing in the sidebar is chosen by it.
struct SearchSidebarRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                Text("Search")
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("⌘F")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Search (⌘F)")
    }
}

/// The Mentions row (the mentions-list spec §4): an `at` symbol, verified
/// present with `NSImage(systemSymbolName:accessibilityDescription:)`, and a
/// badge of unread mentions. It has no context menu and no rules.
struct MentionsSidebarRow: View {
    let unread: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "at")
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text("Mentions")
                .lineLimit(1)
            Spacer(minLength: 4)
            if let badge = MentionsPresentation.badge(unread: unread) {
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(badge) unread")
            }
        }
        .padding(.vertical, 1)
    }
}

/// The Threads row (threads spec §5.3): followed threads, with a badge of the
/// unread ones. No context menu and no rules, like the Mentions row.
struct ThreadsSidebarRow: View {
    let unread: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ThreadsPresentation.rowSymbol)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(ThreadsPresentation.title)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let badge = ThreadsPresentation.badge(unread: unread) {
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(badge) unread")
            }
        }
        .padding(.vertical, 1)
    }
}

/// A row above the conversations. These never scroll (the owner, session 69).
enum PinnedRow: Hashable {
    case search
    case mentions
    case threads
}

/// The sidebar's two lists: the pinned rows, and the conversations below them.
/// Each list selects only its own rows, so a pinned row and a conversation are
/// never highlighted at once.
@MainActor
enum SidebarPinned {
    /// Each row only where its action is offered: Search with
    /// `actions.search`, the gate Edit › Search… uses too.
    static func rows(_ actions: ChatSceneActions) -> [PinnedRow] {
        var rows: [PinnedRow] = []
        if actions.search != nil {
            rows.append(.search)
        }
        if actions.showMentions != nil {
            rows.append(.mentions)
        }
        if actions.threads != nil {
            rows.append(.threads)
        }
        return rows
    }

    /// Search is not here: it opens an overlay and is never selected.
    static func pinnedSelection(_ state: ChatSceneState) -> SidebarSelection? {
        switch state.sidebarSelection {
        case .mentions?: .mentions
        case .threads?: .threads
        case .conversation?, .meetingSeries?, nil: nil
        }
    }

    static func conversationSelection(_ state: ChatSceneState) -> SidebarSelection? {
        switch state.sidebarSelection {
        case .conversation?, .meetingSeries?:
            state.sidebarSelection
        default: nil
        }
    }

    /// What choosing a row in either list asks the host for.
    static func choose(_ selection: SidebarSelection?, actions: ChatSceneActions) {
        switch selection {
        case let .conversation(id)?:
            actions.select(id)
        case let .meetingSeries(id)?:
            actions.selectMeetingSeries?(id)
        case .mentions?:
            actions.showMentions?()
        case .threads?:
            actions.threads?.showList()
        case nil:
            break
        }
    }
}

/// The pinned rows, in a list of their own above the conversations: it never
/// scrolls, and it is exactly as tall as its rows.
///
/// The height is read off the list's own scroll geometry rather than written
/// down, because a sidebar row's height follows the person's sidebar icon size
/// in System Settings. The content size is the rows plus the sidebar style's
/// 10 pt below them. Measured in a hosted window (session 69):
///
/// - **The toolbar band's inset is not added.** A sidebar list extends under
///   the band by itself, outside its frame: framed at 158 pt, its scroll view
///   was 210 tall, and adding the inset left 52 pt of empty rows under Threads.
/// - **The content fills what the list shows, so it grows in place but never
///   shrinks.** With a row taken away it stayed 158 pt. So the caller gives
///   this a new identity for new rows (`.id(rows)`), and a fresh one starts at
///   zero, where the content is only the rows.
struct PinnedList: View {
    let rows: [PinnedRow]
    let state: ChatSceneState
    let actions: ChatSceneActions

    /// Zero until measured, so the list never takes a share of the sidebar
    /// before its rows are known.
    @State private var height: CGFloat = 0

    var body: some View {
        List(selection: selection) {
            ForEach(rows, id: \.self) { row in
                switch row {
                case .search:
                    SearchSidebarRow { actions.search?.show() }
                case .mentions:
                    MentionsSidebarRow(unread: state.unreadMentionCount)
                        .tag(SidebarSelection.mentions)
                case .threads:
                    ThreadsSidebarRow(unread: state.threads.unreadCount)
                        .tag(SidebarSelection.threads)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollDisabled(true)
        .frame(height: height)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height
        } action: { _, needed in
            height = needed
        }
    }

    private var selection: Binding<SidebarSelection?> {
        let selected = SidebarPinned.pinnedSelection(state)
        return Binding(
            get: { selected },
            set: { [actions] in SidebarPinned.choose($0, actions: actions) }
        )
    }
}
