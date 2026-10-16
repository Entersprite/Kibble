import ChatKit
import SwiftUI

struct ConversationManagementPanel: View {
    let details: ConversationDetails
    let state: ChatSceneState
    let actions: ChatSceneActions
    @State private var tab = "about"
    @State private var name = ""
    @State private var description = ""
    @State private var memberQuery = ""
    @State private var adding = false
    @State private var pending: ConversationMutation?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(details.conversation.title ?? "Conversation Details").font(.title2.bold())
                Spacer()
                Button("Done") { actions.browser?.closePanel() }.keyboardShortcut(.cancelAction)
            }
            Picker("Details", selection: $tab) {
                Text("About").tag("about")
                if details.membership == .joined {
                    Text("People").tag("people")
                }
            }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if tab == "people" {
                        people
                    } else {
                        about
                    }
                    if let error = state.browser.panelError {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                    if state.browser.needsReconciliation {
                        Button("Reload Details") { actions.browser?.details(details.conversation.id, false) }
                    }
                    if let notice = state.browser.notice {
                        Text(notice).font(.callout).foregroundStyle(.secondary)
                    }
                    if state.browser.isSubmitting {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .padding(24)
        .onAppear { name = details.conversation.title ?? ""; description = details.description ?? "" }
        .disabled(state.browser.isSubmitting)
        .alert("Confirm Change", isPresented: Binding(
            get: { pending != nil }, set: {
                if !$0 {
                    pending = nil
                }
            }
        )) {
            Button("Confirm", role: .destructive) {
                if let pending {
                    actions.browser?.mutate(pending)
                }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { Text(confirmationMessage) }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                .disabled(!details.allowedActions.contains("rename"))
            if details.conversation.kind == .space {
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(3 ... 6).textFieldStyle(.roundedBorder)
                    .disabled(!details.allowedActions.contains("description"))
            }
            if details.allowedActions.contains("identity") {
                Button("Save Changes") {
                    actions.browser?.mutate(.identity(
                        name: details.allowedActions.contains("rename") ? name : nil,
                        description: details.allowedActions.contains("description") ? description : nil,
                        access: nil
                    ))
                }.buttonStyle(.borderedProminent)
                    .disabled(state.browser.isSubmitting || state.browser
                        .needsReconciliation || !identityChanged)
            }
            if details.membership == .joined, actions.showNotificationSettings != nil {
                Button("Notification and Privacy Settings…") {
                    actions.browser?.closePanel()
                    actions.showNotificationSettings?(details.conversation.id)
                }
            }
            if details.membership != .joined {
                Text("Space Preview").font(.headline)
                if details.previewMessages.isEmpty {
                    Text("No recent messages are available to preview.").foregroundStyle(.secondary)
                }
                ForEach(details.previewMessages, id: \.id) { message in
                    Text(message.text).textSelection(.enabled).lineLimit(8)
                }
            }
            ForEach(joinActions, id: \.action) { mutation in
                Button(actionTitle(mutation.action)) {
                    if mutation == .declineInvitation {
                        pending = mutation
                    } else {
                        actions.browser?.mutate(mutation)
                    }
                }
                .disabled(state.browser.isSubmitting || state.browser.needsReconciliation)
            }
            if details.membership == .requested {
                Text("Your request to join is pending.").foregroundStyle(.secondary)
            }
            Divider()
            if details.allowedActions.contains("leave") {
                Button("Leave Conversation…", role: .destructive) { pending = .leave }.foregroundStyle(.red)
                    .disabled(state.browser.needsReconciliation)
            }
            if details.allowedActions.contains("deleteSpace") {
                Button("Delete Space…", role: .destructive) { pending = .deleteSpace }.foregroundStyle(.red)
                    .disabled(state.browser.needsReconciliation)
            }
        }
    }

    private var identityChanged: Bool {
        let changed = (details.allowedActions
            .contains("rename") && name != (details.conversation.title ?? ""))
            || (details.allowedActions.contains("description") && description != (details.description ?? ""))
        return changed &&
            (details.conversation.kind != .space || !name.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty)
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(adding ? "Find people to add" : "Search members", text: $memberQuery)
                .textFieldStyle(.roundedBorder)
                .onChange(of: memberQuery) {
                    if adding {
                        actions.browser?.searchPeople(memberQuery)
                    }
                }
            if details.allowedActions.contains("addPeople") {
                Toggle("Add People", isOn: $adding).toggleStyle(.button)
                    .onChange(of: adding) {
                        if adding {
                            actions.browser?.searchPeople(memberQuery)
                        }
                    }
            }
            List {
                if adding {
                    ForEach(addCandidates, id: \.id) { member in
                        Button("Add \(member.displayName ?? member.email ?? "Person")") {
                            actions.browser?.mutate(.addPeople([member.id]))
                        }.disabled(state.browser.isSubmitting || state.browser.needsReconciliation)
                    }
                } else {
                    ForEach(filteredParticipants) { participant in memberRow(participant) }
                    if state.browser.hasMoreParticipants {
                        Button("Load More People") { actions.browser?.details(details.conversation.id, true) }
                    }
                }
            }.frame(minHeight: 200, maxHeight: 320)
        }
    }

    private var addCandidates: [Member] {
        let people = memberQuery.isEmpty ? Array(state.directory.values) : state.browser.pickerPeople
        let existing = Set(state.browser.participants.map(\.id))
        return people.filter { $0.kind == .human && $0.id != state.me && !existing.contains($0.id) }
            .sorted { ($0.displayName ?? $0.email ?? "") < ($1.displayName ?? $1.email ?? "") }
    }

    private var filteredParticipants: [ConversationParticipant] {
        state.browser.participants.filter {
            memberQuery.isEmpty || ($0.member.displayName ?? "").localizedCaseInsensitiveContains(memberQuery)
                || ($0.member.email ?? "").localizedCaseInsensitiveContains(memberQuery)
        }
    }

    private func memberRow(_ participant: ConversationParticipant) -> some View {
        HStack {
            Text(participant.member.displayName ?? participant.member.email ?? "Unknown Person")
            Spacer()
            Text(roleTitle(participant.role)).font(.caption).foregroundStyle(.secondary)
            if participant.state != .joined {
                Text(participant.state == .invited ? "Invited" : participant
                    .state == .requested ? "Requested" : "Unknown")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Menu {
                if participant.allowedActions.contains("setRole") {
                    ForEach(participant.allowedRoles.filter { $0 != participant.role }, id: \.self) { role in
                        Button("Make \(roleTitle(role))") { actions.browser?.mutate(.setRole(
                            participant.id,
                            role
                        )) }
                    }
                }
                if participant.allowedActions.contains("approveRequest") {
                    Button("Approve Request") { actions.browser?.mutate(.approveRequest(participant.id)) }
                }
                if participant.allowedActions.contains("rejectRequest") {
                    Button("Reject Request", role: .destructive) { pending = .rejectRequest(participant.id) }
                }
                if participant.allowedActions.contains("removePerson") {
                    Button("Remove Person…", role: .destructive) { pending = .removePerson(participant.id) }
                }
            } label: { Label("Member Actions", systemImage: "ellipsis").labelStyle(.iconOnly) }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(state.browser.isSubmitting || participant.allowedActions.isEmpty)
        }
    }

    private var joinActions: [ConversationMutation] {
        [.join, .requestJoin, .acceptInvitation, .declineInvitation].filter {
            details.allowedActions.contains($0.action)
        }
    }

    private func actionTitle(_ action: String) -> String {
        switch action {
        case "join": "Join Space"
        case "requestJoin": "Request to Join"
        case "acceptInvitation": "Accept Invitation"
        default: "Decline Invitation"
        }
    }

    private func roleTitle(_ role: ConversationRole) -> String {
        switch role {
        case .owner: "Owner"
        case .manager: "Manager"
        case .member: "Member"
        default: "Unknown Role"
        }
    }

    private var confirmationMessage: String {
        if case .declineInvitation = pending {
            return "Decline this invitation to join the space?"
        }
        if case .leave = pending {
            let title = details.conversation.title ?? "this conversation"
            return "Leave \(title)? You will stop receiving its messages."
        }
        if case .deleteSpace = pending {
            return "Delete \(details.conversation.title ?? "this space") for everyone? This cannot be undone."
        }
        if case let .removePerson(id) = pending {
            let name = state.browser.participants.first { $0.id == id }?.member.displayName ?? "this person"
            return "Remove \(name) from \(details.conversation.title ?? "this conversation")?"
        }
        return "Reject this request to join \(details.conversation.title ?? "this conversation")?"
    }
}
