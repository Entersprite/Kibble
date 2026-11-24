import ChatKit
import SwiftUI

public struct BlockedListSettingsState<Row: Identifiable & Equatable & Sendable>: Equatable, Sendable
    where Row.ID: Sendable {
    public let rows: [Row]?
    public let isAvailable: Bool
    public let isLoading: Bool
    public let pending: Row.ID?
    public let error: String?

    public init(
        rows: [Row]?, isAvailable: Bool, isLoading: Bool,
        pending: Row.ID?, error: String?
    ) {
        self.rows = rows
        self.isAvailable = isAvailable
        self.isLoading = isLoading
        self.pending = pending
        self.error = error
    }
}

@MainActor
public struct BlockedListSettingsActions<ID: Hashable> {
    let refresh: () -> Void
    let unblock: (ID) -> Void

    public init(refresh: @escaping () -> Void, unblock: @escaping (ID) -> Void) {
        self.refresh = refresh
        self.unblock = unblock
    }
}

public typealias BlockedConversationsSettingsState = BlockedListSettingsState<BlockedConversation>
public typealias BlockedConversationsSettingsActions = BlockedListSettingsActions<Conversation.ID>
public typealias BlockedPeopleSettingsState = BlockedListSettingsState<BlockedPerson>
public typealias BlockedPeopleSettingsActions = BlockedListSettingsActions<Member.ID>

public struct BlockedConversationsSettingsPane: View {
    let state: BlockedConversationsSettingsState
    let actions: BlockedConversationsSettingsActions

    public init(state: BlockedConversationsSettingsState, actions: BlockedConversationsSettingsActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        BlockedListSettingsPane(
            state: state, actions: actions,
            label: { $0.name.isEmpty ? "Unnamed conversation" : $0.name }, kind: .conversations
        )
    }
}

public struct BlockedPeopleSettingsPane: View {
    let state: BlockedPeopleSettingsState
    let actions: BlockedPeopleSettingsActions

    public init(state: BlockedPeopleSettingsState, actions: BlockedPeopleSettingsActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        BlockedListSettingsPane(
            state: state, actions: actions,
            label: { $0.name.isEmpty ? $0.id.rawValue : $0.name }, kind: .people
        )
    }
}

private struct BlockedListSettingsPane<Row: Identifiable & Equatable & Sendable>: View
    where Row.ID: Sendable {
    enum Kind {
        case conversations, people

        var title: String {
            self == .people ? "Blocked People" : "Blocked Conversations"
        }

        var loading: String {
            self == .people ? "Loading blocked people" : "Loading blocked conversations"
        }
    }

    let state: BlockedListSettingsState<Row>
    let actions: BlockedListSettingsActions<Row.ID>
    let label: (Row) -> String
    let kind: Kind

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(kind.title).font(.headline)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise", action: actions.refresh).disabled(busy)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            contents
            if let error = state.error {
                Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
        .task(id: state.isAvailable) {
            if state.isAvailable {
                actions.refresh()
            }
        }
    }

    private var busy: Bool {
        !state.isAvailable || state.isLoading || state.pending != nil
    }

    @ViewBuilder private var contents: some View {
        if let rows = state.rows, !rows.isEmpty {
            List(rows) { row in
                let name = label(row)
                HStack {
                    Text(name).lineLimit(1)
                    Spacer()
                    if state.pending == row.id {
                        ProgressView().controlSize(.small).accessibilityLabel("Unblocking \(name)")
                    } else {
                        Button("Unblock") { actions.unblock(row.id) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Unblock \(name)")
                            .disabled(busy)
                    }
                }
            }
            .listStyle(.inset)
        } else if !state.isAvailable {
            ContentUnavailableView("Not Connected", systemImage: "wifi.slash")
        } else if state.isLoading || (state.rows == nil && state.error == nil) {
            ProgressView(kind.loading).frame(maxHeight: .infinity)
        } else if state.rows == nil {
            ContentUnavailableView(
                "Couldn’t Load \(kind.title)", systemImage: "exclamationmark.circle"
            )
        } else {
            ContentUnavailableView("No \(kind.title)", systemImage: "hand.raised")
        }
    }
}
