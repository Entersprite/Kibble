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

    @State private var pendingAction: PendingConversationAction?

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
            pendingAction?.action.confirmationTitle ?? "",
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
            Text(pending.title + "\n\n" + pending.action.confirmationMessage)
        }
    }

    private func rowActions(for conversation: Conversation) -> ChatSceneActions {
        var result = actions
        if let original = actions.conversationActions {
            let pending = $pendingAction
            let title = Display.title(of: conversation, directory: state.directory, me: state.me)
            result
                .conversationActions = ConversationActions(capabilities: original
                    .capabilities) { action, id in
                        if action.needsConfirmation {
                            pending.wrappedValue = PendingConversationAction(
                                conversation: id,
                                action: action,
                                title: title,
                                perform: original.perform
                            )
                        } else {
                            original.perform(action, id)
                        }
                }
        }
        return result
    }

    private var conversations: some View {
        List(selection: selectionBinding) {
            ForEach(SidebarProjection.build(
                state.conversations, preferences: state.sidebarPreferences,
                directory: state.directory, me: state.me
            )) { section in
                Section(isExpanded: expansion(of: section.id)) {
                    ForEach(section.items) { item in
                        switch item {
                        case let .meeting(series):
                            let entries = ConversationMenu.entries(
                                for: series, state: state, offers: ConversationMenu.Offers(actions)
                            )
                            MeetingSeriesRow(series: series, state: state)
                                .tag(SidebarSelection.meetingSeries(series.id))
                                .contextMenu { [menuActions = rowActions(for: series.latest)] in
                                    ConversationRowMenu(entries: entries, actions: menuActions)
                                }
                        case let .conversation(conversation):
                            let items = ConversationMenu.items(
                                for: conversation, state: state, offers: ConversationMenu.Offers(actions)
                            )
                            ConversationRow(
                                conversation: conversation,
                                state: ConversationRowState(conversation: conversation, scene: state)
                            )
                            .tag(SidebarSelection.conversation(conversation.id))
                            .contextMenu { [menuActions = rowActions(for: conversation)] in
                                ConversationRowMenu(id: conversation.id, items: items, actions: menuActions)
                            }
                        }
                    }
                    if let showDirectory = actions.showDirectory {
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
        .listStyle(.sidebar)
        .sidebarFade()
        .overlay {
            if state.conversations.isEmpty {
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
            SidebarFooter(state: state, actions: actions)
        }
        // Rows soften as they pass under the bar rather than sliding behind it
        // at full contrast.
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }

    /// Whether one section is expanded, as a binding over the collapsed set.
    ///
    /// `SidebarSection.id` is stable across rebuilds by construction - that is
    /// what its own doc comment promises it for - so a section keeps its
    /// disclosure state while its contents change underneath it, and across
    /// launches where the host keeps it.
    private func expansion(of id: String) -> Binding<Bool> {
        let stored = actions.setSectionCollapsed == nil ? nil : state.collapsedSections
        let local = $collapsed
        let setSection = actions.setSectionCollapsed
        return Binding(
            get: {
                let shut = stored ?? local.wrappedValue
                return !shut.contains(id)
            },
            set: { isExpanded in
                if let setSection {
                    setSection(id, !isExpanded)
                } else if isExpanded {
                    local.wrappedValue.remove(id)
                } else {
                    local.wrappedValue.insert(id)
                }
            }
        )
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

    private func row(now: Date) -> some View {
        HStack(spacing: 8) {
            icon
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
    @ViewBuilder private var icon: some View {
        switch conversation.kind {
        case .directMessage, .appDirectMessage:
            if let other = conversation.members.first(where: { $0 != state.me }) {
                Avatar(
                    member: other,
                    directory: state.directory,
                    size: 20,
                    presence: Display.presence(
                        of: conversation, directory: state.directory, me: state.me,
                        connection: state.connection
                    )
                )
            } else {
                UnknownPersonGlyph(size: 20)
            }
        case .groupDirectMessage:
            MonogramCircle(size: 20) {
                Image(systemName: "person.3.fill").font(.system(size: 9))
            }
        case .space:
            Text("#").fontWeight(.semibold).frame(width: 20).foregroundStyle(.secondary)
        case .meetChat:
            // `video.fill` verified present via
            // `NSImage(systemSymbolName:accessibilityDescription:)` - a wrong
            // symbol name compiles and renders as empty space.
            MeetingPicture()
        case .unknown:
            Image(systemName: "questionmark.circle").frame(width: 20).foregroundStyle(.tertiary)
        }
    }
}
