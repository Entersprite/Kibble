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
