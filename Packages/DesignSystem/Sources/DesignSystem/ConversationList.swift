import ChatKit
import SwiftUI

/// The sidebar.
public struct ConversationList: View {
    let state: ChatSceneState
    let actions: ChatSceneActions

    public init(state: ChatSceneState, actions: ChatSceneActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        List(selection: selectionBinding) {
            ForEach(SidebarSections.build(state.conversations)) { section in
                Section(section.title) {
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter(state: state, actions: actions)
        }
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
    @ViewBuilder private var icon: some View {
        switch conversation.kind {
        case .directMessage, .appDirectMessage:
            if let other = conversation.members.first(where: { $0 != state.me }) {
                Avatar(member: other, directory: state.directory, size: 20)
            } else {
                Image(systemName: "person").frame(width: 20)
            }
        case .groupDirectMessage:
            Image(systemName: "person.2").frame(width: 20).foregroundStyle(.secondary)
        case .space:
            Text("#").fontWeight(.semibold).frame(width: 20).foregroundStyle(.secondary)
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
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    identity
                    Spacer(minLength: 4)
                    Button("Sign Out…", action: signOut)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.secondary.opacity(0.08))
        }
    }

    /// `Display.signedInLabel` already decides what to show when `state.me`
    /// has not resolved yet - see its own doc comment - so this only has to
    /// draw an avatar or a neutral stand-in for the same gap.
    @ViewBuilder private var identity: some View {
        if let me = state.me {
            Avatar(member: me, directory: state.directory, size: 20)
        } else {
            Image(systemName: "person.crop.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        }
        Text(Display.signedInLabel(me: state.me, directory: state.directory))
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(.secondary)
    }
}
