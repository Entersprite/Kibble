import ChatKit
import SwiftUI

/// The sidebar.
public struct ConversationList: View {
    let state: ChatSceneState
    let actions: ChatSceneActions

    /// Which sections are **collapsed**, keyed by `SidebarSection.id`, for a
    /// host that keeps none (`SectionCollapse`). A host that keeps them hands
    /// them back in `state.collapsedSections`, so collapse survives a relaunch.
    ///
    /// Collapsed rather than expanded, so the empty default means everything
    /// is open - and, more usefully, so a section appearing for the first time
    /// arrives expanded instead of silently hidden. That matters here: a new
    /// `Kind.unknown` group type mints a section nobody has seen before
    /// (`findings.md` §37.4), and defaulting it shut would hide the very thing
    /// those sections exist to surface.
    @State private var collapsed: Set<String> = []

    public init(state: ChatSceneState, actions: ChatSceneActions) {
        self.state = state
        self.actions = actions
    }

    func accountUnavailable(_ unavailable: Bool) -> Self {
        var list = self
        list.isAccountUnavailable = unavailable
        return list
    }

    @State private var pendingAction: PendingConversationAction?
    /// Present under `AccountShell`, which draws the account pill itself.
    @Environment(\.accountFooter) private var accountFooter
    /// The selected account is not running: no sections and no "nothing has
    /// synced" note, only the empty list that keeps the footer in its place.
    var isAccountUnavailable = false

    /// Two lists: the pinned rows, which never scroll (`PinnedList`), and the
    /// conversations below them. A second list rather than a bar over the
    /// conversations, so the pinned rows keep the system's own selection and
    /// row height, and no second scroll-edge blur joins the window's
    /// (CLAUDE.md, the titlebar section rules).
    public var body: some View {
        VStack(spacing: 0) {
            let pinned = SidebarPinned.rows(actions)
            if !pinned.isEmpty {
                PinnedList(rows: pinned, state: state, actions: actions)
                    // Measured afresh for new rows: see `PinnedList`'s height.
                    .id(pinned)
            }
            conversations
        }
        .alert(
            pendingAction?.confirmationTitle ?? "",
            isPresented: Binding(get: { pendingAction != nil }, set: {
                if !$0 {
                    pendingAction = nil
                }
            }),
            presenting: pendingAction
        ) { pending in
            Button(pending.action.confirmationButton, role: .destructive) {
                pending.perform(pending.action, pending.conversation)
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.action.confirmationMessage)
        }
        // A confirmation asked in one account does not wait in another.
        .onChange(of: state.accountID) { pendingAction = nil }
    }

    /// `actions` with the conversation actions that need a confirmation
    /// asking for one first, about the conversation called `title`.
    private func confirming(_ actions: ChatSceneActions, title: String) -> ChatSceneActions {
        var result = actions
        if let original = actions.conversationActions {
            let pending = $pendingAction
            let capabilities = original.capabilities
            result.conversationActions = ConversationActions(capabilities: capabilities) { action, id in
                if action.needsConfirmation {
                    pending.wrappedValue = PendingConversationAction(
                        conversation: id, action: action, title: title, perform: original.perform
                    )
                } else {
                    original.perform(action, id)
                }
            }
        }
        return result
    }

    /// The menu for a right-clicked row, built when the menu opens rather
    /// than with every row on every render, from the sections and state this
    /// list was drawn with.
    @ViewBuilder
    private func rowMenu(_ clicked: Set<SidebarSelection>, in sections: [SidebarSection]) -> some View {
        if let menu = ConversationMenu.rowMenu(
            for: clicked, in: sections, state: state, offers: ConversationMenu.Offers(actions)
        ) {
            ConversationRowMenu(
                entries: menu.entries, favoriteTarget: menu.favorite,
                preferences: state.sidebarPreferences, actions: confirming(actions, title: menu.title)
            )
        }
    }

    private var conversations: some View {
        let sections = isAccountUnavailable ? [] : SidebarProjection.build(
            state.conversations, preferences: state.sidebarPreferences,
            directory: state.directory, me: state.me
        )
        return List(selection: selectionBinding) {
            ForEach(sections) { section in
                Section(
                    isExpanded: SectionCollapse.expansion(
                        of: section.id, state: state, actions: actions, local: $collapsed
                    )
                ) {
                    ForEach(section.items) { item in
                        switch item {
                        case let .meeting(series):
                            MeetingSeriesRow(series: series, state: state)
                                .tag(SidebarSelection.meetingSeries(series.id))
                        case let .conversation(conversation):
                            ConversationRow(
                                conversation: conversation,
                                state: ConversationRowState(conversation: conversation, scene: state)
                            )
                            .tag(SidebarSelection.conversation(conversation.id))
                        }
                    }
                    if section.id != "favorites", let showDirectory = actions.showDirectory {
                        SidebarSeeAllRow(title: section.title) { showDirectory(section.id) }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title)
                        if section.id == "meetChat", state.isLoadingMeetingMetadata {
                            MeetingMetadataProgress()
                        }
                    }
                }
                .sectionActions {
                    if let update = actions.updateSidebar {
                        SidebarSectionMenu(
                            id: section.id, preferences: state.sidebarPreferences, update: update,
                            showSettings: actions.showSidebarSettings
                        )
                    }
                }
            }
        }
        // One menu for the whole list, resolved for the clicked row when it
        // opens. A `.contextMenu` on each row built every row's menu with the
        // row, on every render (CLAUDE.md, menus are built with the view).
        .contextMenu(forSelectionType: SidebarSelection.self) { clicked in
            rowMenu(clicked, in: sections)
        }
        .listStyle(.sidebar)
        .sidebarFade()
        .overlay {
            if state.conversations.isEmpty, !isAccountUnavailable {
                ContentUnavailableView(
                    "No conversations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Nothing has synced yet.")
                )
            }
        }
        // `safeAreaBar`, not `safeAreaInset`: this is the macOS 26 API for a
        // bar pinned to a safe-area edge, and it brings the system's own glass
        // treatment and its coordination with scroll-edge effects. The inset
        // version placed the footer correctly but left its backdrop entirely up
        // to the footer, which is how it ended up 92% transparent with sidebar
        // rows reading straight through it.
        //
        // Never `.mask` this list: the bar's blur is drawn inside the list's
        // scroll view, and under a masked ancestor it renders as a flat gray
        // band with the rows cut off at its edge. `SidebarFade` masks only the
        // rows' clip view for that reason.
        .safeAreaBar(edge: .bottom) {
            // Under `AccountShell` the row is reserved and measured here, and
            // the pill drawn above the window so its panel can grow past the sidebar.
            if let accountFooter {
                AccountFooterAnchor(geometry: accountFooter)
            } else {
                SidebarFooter(state: state, actions: actions)
            }
        }
        // Rows soften as they pass under the bar rather than sliding behind it
        // at full contrast.
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }

    /// Conversations only: a pinned row is selected in `PinnedList`.
    private var selectionBinding: Binding<SidebarSelection?> {
        let selected = SidebarPinned.conversationSelection(state)
        return Binding(
            get: { selected },
            set: { [actions] in SidebarPinned.choose($0, actions: actions) }
        )
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    let state: ConversationRowState
    /// The person's sidebar icon size (System Settings), which the picture follows.
    @Environment(\.sidebarRowSize) private var rowSize

    private var showsUnread: Bool {
        state.showsUnread
    }

    var body: some View {
        // Redrawn exactly at the DM partner's boundaries (spec §6.3). `.now`,
        // not the timeline's date, so a redraw for any other reason draws now.
        TimelineView(.explicit(Display.redrawDates(for: partner, now: .now))) { _ in
            row(now: .now)
        }
        .padding(.vertical, 1)
        // Dimmed whenever the resolved delivery is Off (spec §2.5).
        // `[Verify]` the value against the selection highlight in the
        // running app.
        .opacity(state.dimmed ? 0.55 : 1)
    }

    private var partner: Member? {
        Display.dmPartner(of: conversation, directory: state.directory, me: state.me)
    }

    /// The picture beside the name in a plain stack, never a `Label`'s icon
    /// slot: the sidebar redraws what sits in that slot in its own style,
    /// which turned the away ring black in a focused window and dropped
    /// presence badges (owner's screenshots), and gave rows uneven heights.
    private func row(now: Date) -> some View {
        let side = SidebarRowPicture.diameter(rowSize)
        return HStack(spacing: 8) {
            icon
                .frame(width: side, height: side)
            Text(Display.title(of: conversation, directory: state.directory, me: state.me))
                .lineLimit(1)
                // `hasUnread`, not `unreadCount`: the count is always zero on
                // the wire (`findings.md` §37.8), so weighting on it meant no
                // conversation was ever bold.
                .fontWeight(showsUnread ? .semibold : .regular)
            Spacer(minLength: 4)
            // After the spacer, so the marks sit at the trailing edge, beside
            // the mute bell and the unread dot, rather than after the name.
            if let marks = PersonMarks(
                status: Display.status(
                    of: conversation, directory: state.directory, me: state.me, connection: state.connection,
                    now: now
                ),
                calendar: Display.calendar(
                    of: conversation, directory: state.directory, me: state.me, connection: state.connection,
                    now: now
                ),
                now: now
            ) {
                marks
            }
            // Google's own mute (`Conversation.isMuted`, only the fixture
            // sets it) or this account's local record (decision 1).
            if conversation.isMuted || state.muted {
                Image(systemName: "bell.slash")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            unreadMarker
        }
    }

    /// A number when the backend can count, a dot when it can only say
    /// "something" in the main conversation, and
    /// nothing when there is nothing.
    ///
    /// Both cases exist because the two facts arrive separately and Chat
    /// currently supplies only the second: `unread_message_count` is sent as
    /// zero on every conversation (`findings.md` §37.8), so in practice this
    /// draws the dot. The numeric branch is kept rather than deleted because
    /// `Conversation.unreadCount` is part of the wire format and a different
    /// backend - a future bridge server, or Chat itself if the field ever
    /// starts arriving - can populate it without a client change.
    ///
    /// The dot is trailing, where the badge already sat, rather than leading
    /// as first sketched: the row already opens with an avatar or a hash, and
    /// a second leading mark competes with it.
    ///
    /// `.tint` rather than a literal colour, so it follows the system accent.
    /// That is the selection-and-emphasis role the guidelines reserve the
    /// accent for, and it is distinct from the advice against fixed-colour
    /// sidebar *icons* - this is state, not iconography.
    @ViewBuilder private var unreadMarker: some View {
        if !state.unreadHidden, conversation.unreadCount > 0 {
            Text("\(conversation.unreadCount)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else if showsUnread {
            Circle()
                .fill(.tint)
                .frame(width: 7, height: 7)
                .accessibilityLabel("Unread")
        }
    }

    /// A space gets a hash, a person gets their face, and a conversation kind
    /// this build does not recognise gets a neutral marker rather than being
    /// drawn as something it might not be.
    ///
    /// A group gets Messages' cluster - approximated with `person.3.fill` on the
    /// same disc every other avatar uses. Apple's own group composite is
    /// artwork, not a symbol, so this is the nearest stock thing rather than the
    /// identical one.
    ///
    /// The name sits beside every one of these, so VoiceOver skips the
    /// picture and reads the name, keeping a DM partner's presence.
    @ViewBuilder private var icon: some View {
        let size = SidebarRowPicture.diameter(rowSize)
        switch conversation.kind {
        case .directMessage, .appDirectMessage:
            if let other = conversation.members.first(where: { $0 != state.me }) {
                Avatar(
                    member: other,
                    directory: state.directory,
                    size: size,
                    presence: Display.presence(
                        of: conversation, directory: state.directory, me: state.me,
                        connection: state.connection
                    )
                )
                .besideName()
            } else {
                UnknownPersonGlyph(size: size).accessibilityHidden(true)
            }
        case .groupDirectMessage:
            MonogramCircle(size: size) {
                Image(systemName: "person.3.fill").font(.system(size: size * 0.45))
            }
            .accessibilityHidden(true)
        case .space:
            // A symbol rather than a typed "#", so it is sized as the sidebar
            // sizes its other icons, in a concrete color (`SidebarSymbol`).
            SidebarSymbol(name: SidebarRowPicture.spaceSymbol)
                .accessibilityHidden(true)
        case .meetChat:
            MeetingPicture(size: size).accessibilityHidden(true)
        case .unknown:
            SidebarSymbol(name: "questionmark.circle").accessibilityHidden(true)
        }
    }
}

/// How big a sidebar row's picture is: the size the sidebar draws a `Label`'s
/// symbol at for the person's sidebar icon size (System Settings ›
/// Appearance). Measured in a hosted sidebar list on macOS 27, the `at`
/// symbol's frame was about 16, 20 and 23 points for small, medium and large.
enum SidebarRowPicture {
    static func diameter(_ size: SidebarRowSize) -> CGFloat {
        switch size {
        case .small: 16
        case .large: 24
        default: 20
        }
    }

    /// Checked to exist by `SidebarSymbolTests`.
    static let spaceSymbol = "number"
}
