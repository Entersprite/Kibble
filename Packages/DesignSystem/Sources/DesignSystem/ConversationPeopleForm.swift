import ChatKit
import SwiftUI

/// The People tab: one field that filters the members and, where the person
/// may add people, finds others to add, the way a team's member list does.
/// Each member's actions are in a menu at the row's end and in its context
/// menu; a destructive one goes through the sheet's confirmation.
struct ConversationPeopleForm: View {
    let details: ConversationDetails
    let state: ChatSceneState
    let actions: ConversationBrowserActions
    let confirm: (ConversationMutation) -> Void
    @State private var query = ""

    private var canAdd: Bool {
        details.allowedActions.contains("addPeople")
    }

    private var isBusy: Bool {
        state.browser.isSubmitting || state.browser.needsReconciliation
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(
                        "Search",
                        text: $query,
                        prompt: Text(canAdd ? "Search members or add people" : "Search members")
                    )
                    .labelsHidden()
                    .onChange(of: query) {
                        if canAdd {
                            actions.searchPeople(query)
                        }
                    }
                }
            }
            if canAdd, !query.isEmpty {
                adding
            }
            members
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var adding: some View {
        Section {
            ForEach(addCandidates, id: \.id) { person in
                PersonRow(person: person) {
                    Button("Add") { actions.mutate(.addPeople([person.id])) }
                        .controlSize(.small)
                        .disabled(isBusy)
                }
            }
            if addCandidates.isEmpty, !state.browser.isSearchingPeople {
                Text("No one else matches “\(query)”.").foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 6) {
                Text("Add People")
                if state.browser.isSearchingPeople {
                    ProgressView().controlSize(.mini)
                }
            }
        }
    }

    private var members: some View {
        Section {
            ForEach(filteredParticipants) { participant in
                PersonRow(person: participant.member) {
                    trailing(for: participant)
                }
                .contextMenu { menuItems(for: participant) }
            }
            if filteredParticipants.isEmpty, !query.isEmpty {
                Text("No members match “\(query)”.").foregroundStyle(.secondary)
            }
            if state.browser.hasMoreParticipants {
                Button("Show More People") { actions.details(details.conversation.id, true) }
                    .buttonStyle(.link)
            }
        } header: {
            Text(membersTitle)
        }
    }

    private var membersTitle: String {
        guard let count = details.conversation.memberCount else { return "Members" }
        return count == 1 ? "1 Member" : "\(count) Members"
    }

    private func trailing(for participant: ConversationParticipant) -> some View {
        HStack(spacing: 8) {
            switch participant.state {
            case .invited: Text("Invited").foregroundStyle(.secondary)
            case .requested: Text("Requested").foregroundStyle(.secondary)
            default: EmptyView()
            }
            // A member is the ordinary case; only the roles above it are named.
            if participant.role == .owner || participant.role == .manager {
                Text(ConversationDetailsText.role(participant.role)).foregroundStyle(.secondary)
            }
            if participant.allowedActions.contains("approveRequest") {
                Button("Approve") { actions.mutate(.approveRequest(participant.id)) }
                    .controlSize(.small)
                    .disabled(isBusy)
            }
            if !participant.allowedActions.isEmpty {
                Menu {
                    menuItems(for: participant)
                } label: {
                    Label("Actions for \(PersonName.of(participant.member))", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(isBusy)
                .help("Actions")
            }
        }
        .font(.subheadline)
    }

    @ViewBuilder private func menuItems(for participant: ConversationParticipant) -> some View {
        if participant.allowedActions.contains("setRole") {
            ForEach(participant.allowedRoles.filter { $0 != participant.role }, id: \.self) { role in
                Button("Make \(ConversationDetailsText.role(role))") {
                    actions.mutate(.setRole(participant.id, role))
                }
            }
        }
        if participant.allowedActions.contains("approveRequest") {
            Button("Approve Request") { actions.mutate(.approveRequest(participant.id)) }
        }
        if participant.allowedActions.contains("rejectRequest") {
            Button("Reject Request…", role: .destructive) { confirm(.rejectRequest(participant.id)) }
        }
        if participant.allowedActions.contains("removePerson") {
            Divider()
            Button(
                "Remove from \(ConversationDetailsText.kind(details.conversation.kind))…",
                role: .destructive
            ) {
                confirm(.removePerson(participant.id))
            }
        }
    }

    private var addCandidates: [Member] {
        PeopleDirectoryProjection.candidates(
            in: state,
            query: query,
            found: state.browser.pickerPeople,
            excluding: Set(state.browser.participants.map(\.id))
        )
    }

    private var filteredParticipants: [ConversationParticipant] {
        state.browser.participants.filter {
            query.isEmpty || ($0.member.displayName ?? "").localizedCaseInsensitiveContains(query)
                || ($0.member.email ?? "").localizedCaseInsensitiveContains(query)
        }
    }
}
