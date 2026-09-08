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
            ForEach(SidebarSections.build(state.conversations)) { section in
                Section(section.title, isExpanded: expansion(of: section.id)) {
                    ForEach(section.conversations, id: \.id) { conversation in
                        ConversationRow(conversation: conversation, state: state)
                            .tag(conversation.id)
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

    private var selectionBinding: Binding<Conversation.ID?> {
        Binding(
            get: { state.selected },
            set: {
                if let id = $0 {
                    actions.select(id)
                }
            }
        )
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    let state: ChatSceneState

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(Display.title(of: conversation, directory: state.directory, me: state.me))
                .lineLimit(1)
                .fontWeight(conversation.unreadCount > 0 ? .semibold : .regular)
            Spacer(minLength: 4)
            if conversation.isMuted {
                Image(systemName: "bell.slash")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if conversation.unreadCount > 0 {
                Text("\(conversation.unreadCount)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
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
                Avatar(member: other, directory: state.directory, size: 20)
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
            HStack(spacing: 10) {
                identity
                Spacer(minLength: 8)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    /// `Display.signedInLabel` already decides what to show when `state.me`
    /// has not resolved yet - see its own doc comment - so this only has to
    /// draw an avatar or a neutral stand-in for the same gap.
    @ViewBuilder private var identity: some View {
        if let me = state.me {
            Avatar(member: me, directory: state.directory, size: 28)
        } else {
            UnknownPersonGlyph(size: 28)
        }
        Text(Display.signedInLabel(me: state.me, directory: state.directory))
            .font(.callout)
            .lineLimit(1)
            .foregroundStyle(.primary)
    }
}
