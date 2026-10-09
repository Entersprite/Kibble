import ChatKit
import SwiftUI

/// The sidebar.
public struct ConversationList: View {
    let state: ChatSceneState
    let actions: ChatSceneActions

    /// Which sections are **collapsed**, keyed by `SidebarSection.id`.
    ///
    /// Collapsed rather than expanded, so the empty default means everything
    /// is open - and, more usefully, so a section appearing for the first time
    /// arrives expanded instead of silently hidden. That matters here: a new
    /// `Kind.unknown` group type mints a section nobody has seen before
    /// (`findings.md` §37.4), and defaulting it shut would hide the very thing
    /// those sections exist to surface.
    ///
    /// `@State`, so **collapse does not survive relaunch.** Persisting it
    /// needs a decision this view cannot make: `DesignSystem` takes values and
    /// hands back callbacks, and reaching for `UserDefaults` here would be the
    /// first time a view in this package owned durable state. The honest
    /// options are a `ChatSceneActions`-style callback or host-provided
    /// storage; neither is worth building before anyone asks.
    @State private var collapsed: Set<String> = []

    public init(state: ChatSceneState, actions: ChatSceneActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        List(selection: selectionBinding) {
            // Pinned above the first section, and drawn only where the host
            // offers it (`ChatSceneActions.showMentions`).
            if actions.showMentions != nil {
                MentionsSidebarRow(unread: state.unreadMentionCount)
                    .tag(SidebarSelection.mentions)
            }
            if actions.threads != nil {
                ThreadsSidebarRow(unread: state.threads.unreadCount)
                    .tag(SidebarSelection.threads)
            }
            ForEach(SidebarSections.build(state.conversations)) { section in
                Section(section.title, isExpanded: expansion(of: section.id)) {
                    ForEach(section.conversations, id: \.id) { conversation in
                        ConversationRow(conversation: conversation, state: state)
                            .tag(SidebarSelection.conversation(conversation.id))
                            .contextMenu { menu(for: conversation) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
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
        .safeAreaBar(edge: .bottom) {
            SidebarFooter(state: state, actions: actions)
        }
        // Rows soften as they pass under the bar rather than sliding behind it
        // at full contrast.
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }

    /// Whether one section is expanded, as a binding over `collapsed`.
    ///
    /// `SidebarSection.id` is stable across rebuilds by construction - that is
    /// what its own doc comment promises it for - so a section keeps its
    /// disclosure state while its contents change underneath it.
    private func expansion(of id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    collapsed.remove(id)
                } else {
                    collapsed.insert(id)
                }
            }
        )
    }

    private var selectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: { state.sidebarSelection },
            set: { selection in
                switch selection {
                case let .conversation(id)?:
                    actions.select(id)
                case .mentions?:
                    actions.showMentions?()
                case .threads?:
                    actions.threads?.showList()
                case nil:
                    break
                }
            }
        )
    }

    /// Draws `ConversationMenu.items`, which decides what is offered - an
    /// item appears only where its action was supplied, so each closure below
    /// is present whenever its button is.
    private func menu(for conversation: Conversation) -> some View {
        let id = conversation.id
        let items = ConversationMenu.items(
            for: conversation,
            state: state,
            offers: ConversationMenu.Offers(actions)
        )
        return ForEach(items, id: \.self) { item in
            switch item {
            case .markAsRead:
                Button("Mark as Read") { actions.markRead?(id) }
                Divider()
            case .mute:
                Button("Mute") { actions.mute?(id) }
            case .unmute:
                Button("Unmute") { actions.unmute?(id) }
            case .notificationSettings:
                Button("Notification Settings…") { actions.showNotificationSettings?(id) }
            }
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    let state: ChatSceneState

    private var showsUnread: Bool {
        ThreadsPresentation.showsUnread(
            conversation, hidden: state.unreadHidden.contains(conversation.id),
            unreadThreads: state.threads.unreadConversations
        )
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
        .opacity(state.dimmed.contains(conversation.id) ? 0.55 : 1)
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
            if conversation.isMuted || state.muted.contains(conversation.id) {
                Image(systemName: "bell.slash")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            unreadMarker
        }
    }

    /// A number when the backend can count, a dot when it can only say
    /// "something" (a followed thread's activity included, session 58), and
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
        if !state.unreadHidden.contains(conversation.id), conversation.unreadCount > 0 {
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
            MonogramCircle(size: 20) {
                Image(systemName: "video.fill").font(.system(size: 9))
            }
        case .unknown:
            Image(systemName: "questionmark.circle").frame(width: 20).foregroundStyle(.tertiary)
        }
    }
}

/// Who is signed in, and the way to stop - the sidebar's fixed bottom row.
///
/// Drawn only when `actions.signOut` is offered, the same rule `StatusStrip`
/// already applies to `actions.signIn`: a host with no running session has
/// nothing to sign out of, so this draws nothing rather than a button that
/// does nothing. That also keeps this from ever showing a half-built
/// identity next to a control that cannot act on it - there is no running
/// session either way.
struct SidebarFooter: View {
    let state: ChatSceneState
    let actions: ChatSceneActions

    var body: some View {
        if let signOut = actions.signOut {
            // No `Divider()` and no tinted background: both existed to fake a
            // separation `safeAreaBar` now provides, and keeping them would
            // draw it twice.
            // Redrawn at your own boundaries, like a DM row (spec §6.3), and when Do not disturb ends.
            TimelineView(.explicit(Display.ownRedrawDates(
                for: state.me.flatMap { state.directory[$0] },
                availability: state.availability,
                now: .now
            ))) { _ in
                HStack(spacing: 10) {
                    if state.capabilities.canSetStatus, let setStatus = actions.setStatus,
                       let setAvailability = actions.setAvailability {
                        OwnStatusMenu(
                            state: state, setStatus: setStatus, setAvailability: setAvailability,
                            reactions: actions.reactions
                        ) {
                            HStack(spacing: 10) { identity }
                        }
                    } else {
                        identity
                    }
                    Spacer(minLength: 8)
                    ownMarks
                    // Icon-only, but built from a `Label` rather than a bare
                    // `Image`: `.iconOnly` hides the text visually and keeps it as
                    // the accessibility label, so VoiceOver still says "Sign Out"
                    // instead of reading a symbol name. `.help` gives the same
                    // words back as a tooltip on macOS.
                    Button(action: signOut) {
                        Label("Sign Out…", systemImage: "rectangle.portrait.and.arrow.right")
                            .labelStyle(.iconOnly)
                            .font(.body)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Sign Out…")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    /// `Display.signedInLabel` already decides what to show when `state.me`
    /// has not resolved yet - see its own doc comment - so this only has to
    /// draw an avatar or a neutral stand-in for the same gap.
    @ViewBuilder private var identity: some View {
        if let me = state.me {
            Avatar(
                member: me, directory: state.directory, size: 28,
                presence: Display.ownPresence(
                    availability: state.availability, directory: state.directory, me: me,
                    connection: state.connection, now: .now
                )
            )
        } else {
            UnknownPersonGlyph(size: 28)
        }
        Text(Display.signedInLabel(me: state.me, directory: state.directory))
            .font(.callout)
            .lineLimit(1)
            .foregroundStyle(.primary)
    }

    /// Your own status and calendar marks, the one place they are drawn
    /// (spec §6.2): at the trailing edge, beside Sign Out, as a DM row's are.
    @ViewBuilder private var ownMarks: some View {
        if let marks = PersonMarks(
            status: Display.ownStatus(
                directory: state.directory, me: state.me, connection: state.connection, now: .now
            ),
            calendar: Display.ownCalendar(
                directory: state.directory, me: state.me, connection: state.connection, now: .now
            ),
            now: .now
        ) {
            marks
        }
    }
}
