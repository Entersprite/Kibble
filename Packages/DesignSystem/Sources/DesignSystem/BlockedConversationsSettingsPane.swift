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

/// One blocked list as the Privacy pane takes it: its state, its actions and
/// the session they belong to, so a list never outlives its account.
@MainActor
public struct BlockedListSettings<Row: Identifiable & Equatable & Sendable> where Row.ID: Sendable {
    let state: BlockedListSettingsState<Row>
    let actions: BlockedListSettingsActions<Row.ID>
    let session: AnyHashable

    public init(
        state: BlockedListSettingsState<Row>, actions: BlockedListSettingsActions<Row.ID>,
        session: AnyHashable = 0
    ) {
        self.state = state
        self.actions = actions
        self.session = session
    }
}

/// Settings › Privacy: who and what this account has blocked, as one grouped
/// form with a section per list, the way System Settings lists things a
/// person can take back. A list the account cannot manage is left out.
public struct PrivacySettingsPane: View {
    let conversations: BlockedListSettings<BlockedConversation>?
    let people: BlockedListSettings<BlockedPerson>?

    public init(
        conversations: BlockedListSettings<BlockedConversation>?,
        people: BlockedListSettings<BlockedPerson>?
    ) {
        self.conversations = conversations
        self.people = people
    }

    public var body: some View {
        if conversations == nil, people == nil {
            ContentUnavailableView(
                "Nothing to Manage", systemImage: "hand.raised",
                description: Text("This account doesn’t offer blocking.")
            )
        } else {
            Form {
                if let people {
                    BlockedListSection(
                        state: people.state, actions: people.actions,
                        label: { $0.name.isEmpty ? "Unnamed Person" : $0.name }, kind: .people
                    )
                    .id(BlockedListCopy.Identity(kind: .people, session: people.session))
                }
                if let conversations {
                    BlockedListSection(
                        state: conversations.state, actions: conversations.actions,
                        label: { $0.name.isEmpty ? "Unnamed Conversation" : $0.name }, kind: .conversations
                    )
                    .id(BlockedListCopy.Identity(kind: .conversations, session: conversations.session))
                }
            }
            .formStyle(.grouped)
        }
    }
}

public struct BlockedConversationsSettingsPane: View {
    let state: BlockedConversationsSettingsState
    let actions: BlockedConversationsSettingsActions

    public init(state: BlockedConversationsSettingsState, actions: BlockedConversationsSettingsActions) {
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        PrivacySettingsPane(conversations: .init(state: state, actions: actions), people: nil)
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
        PrivacySettingsPane(conversations: nil, people: .init(state: state, actions: actions))
    }
}

/// What a blocked list says, apart from its rows. Pure, so each state is a test.
enum BlockedListCopy {
    enum Kind {
        case conversations, people

        var title: String {
            self == .people ? "Blocked People" : "Blocked Conversations"
        }

        var noun: String {
            self == .people ? "people" : "conversations"
        }
    }

    /// A section's identity: its list and its session, so two lists of one
    /// session stay two views and a new session starts each afresh.
    struct Identity: Hashable {
        let kind: Kind
        let session: AnyHashable
    }

    /// The line that stands in for the rows while there are none to show.
    static func placeholder(
        _ kind: Kind, hasRows: Bool, isAvailable: Bool, isLoading: Bool, failed: Bool
    ) -> String? {
        if hasRows {
            return nil
        }
        if !isAvailable {
            return "Not connected."
        }
        if isLoading {
            return "Loading…"
        }
        return failed ? "Couldn’t load blocked \(kind.noun)." : "No blocked \(kind.noun)."
    }
}

/// One list: a name and Unblock on each row, the list's progress and Refresh
/// in its header, and what went wrong as a row of its own.
private struct BlockedListSection<Row: Identifiable & Equatable & Sendable>: View
    where Row.ID: Sendable {
    let state: BlockedListSettingsState<Row>
    let actions: BlockedListSettingsActions<Row.ID>
    let label: (Row) -> String
    let kind: BlockedListCopy.Kind

    var body: some View {
        Section {
            ForEach(state.rows ?? []) { row in
                let name = label(row)
                LabeledContent {
                    if state.pending == row.id {
                        ProgressView().controlSize(.small).accessibilityLabel("Unblocking \(name)")
                    } else {
                        Button("Unblock") { actions.unblock(row.id) }
                            .controlSize(.small)
                            .accessibilityLabel("Unblock \(name)")
                            .disabled(busy)
                    }
                } label: {
                    Text(name).lineLimit(1)
                }
            }
            if let placeholder = BlockedListCopy.placeholder(
                kind, hasRows: state.rows?.isEmpty == false, isAvailable: state.isAvailable,
                isLoading: state.isLoading || (state.rows == nil && state.error == nil),
                failed: state.rows == nil
            ) {
                Text(placeholder).foregroundStyle(.secondary)
            }
            if let error = state.error {
                SheetErrorRow(message: error)
            }
        } header: {
            HStack(spacing: 6) {
                Text(kind.title)
                if state.isLoading {
                    ProgressView().controlSize(.mini)
                }
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
}
