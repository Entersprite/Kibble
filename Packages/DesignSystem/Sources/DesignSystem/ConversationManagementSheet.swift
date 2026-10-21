import ChatKit
import SwiftUI

/// A conversation's details: About (name, description, notifications,
/// leaving) and, once joined, its People. For a space not yet joined it is
/// the preview, with Join as the default button.
///
/// Buttons follow the Mac's sheet rules: the default button trails, Cancel
/// sits before it, and a destructive choice is never the default. Edits to
/// the name and description are saved with Save; Cancel discards them.
struct ConversationManagementSheet: View {
    let details: ConversationDetails
    let state: ChatSceneState
    let actions: ConversationBrowserActions
    let openNotifications: ((Conversation.ID) -> Void)?
    @State private var tab = Tab.about
    @State private var name = ""
    @State private var description = ""
    @State private var pending: ConversationMutation?

    private enum Tab: Hashable {
        case about, people
    }

    var body: some View {
        Group {
            if tab == .people, isJoined {
                ConversationPeopleForm(details: details, state: state, actions: actions) { pending = $0 }
            } else {
                about
            }
        }
        .safeAreaBar(edge: .top) { header }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .frame(width: 520, height: 520)
        .toolbar { buttons }
        .disabled(state.browser.isSubmitting)
        .onExitCommand(perform: actions.closePanel)
        .onAppear(perform: reset)
        .onChange(of: details) { reset() }
        .alert(
            pending
                .map { ConversationDetailsText.confirmationTitle($0, details: details, state: state) } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { shown in
                if !shown {
                    pending = nil
                }
            }),
            presenting: pending
        ) { mutation in
            Button(ConversationDetailsText.confirmationButton(mutation), role: .destructive) {
                actions.mutate(mutation)
            }
            Button("Cancel", role: .cancel) {}
        } message: { mutation in
            Text(ConversationDetailsText.confirmationMessage(mutation))
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            SheetHeader(title: title, message: ConversationDetailsText.subtitle(details)) {
                ConversationPicture(
                    conversation: details.conversation,
                    directory: state.directory,
                    me: state.me,
                    size: 40
                )
            }
            if isJoined {
                Picker("Show", selection: $tab) {
                    Text("About").tag(Tab.about)
                    Text("People").tag(Tab.people)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.bottom, 4)
            }
        }
    }

    private var title: String {
        Display.title(of: details.conversation, directory: state.directory, me: state.me)
    }

    private var isJoined: Bool {
        details.membership == .joined
    }

    private var isSpace: Bool {
        details.conversation.kind == .space
    }

    private func allows(_ action: String) -> Bool {
        details.allowedActions.contains(action)
    }

    private func reset() {
        name = details.conversation.title ?? ""
        description = details.description ?? ""
    }

    // MARK: About

    private var about: some View {
        Form {
            status
            Section {
                if allows("rename") {
                    TextField("Name", text: $name, prompt: Text(isSpace ? "Required" : "Optional"))
                } else {
                    LabeledContent("Name", value: title)
                }
                if isSpace {
                    if allows("description") {
                        TextField(
                            "Description",
                            text: $description,
                            prompt: Text("Optional"),
                            axis: .vertical
                        )
                        .lineLimit(2 ... 5)
                    } else if let text = details.description, !text.isEmpty {
                        LabeledContent("Description") {
                            Text(text).multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            if !isJoined {
                preview
            }
            if isJoined, let openNotifications {
                Section {
                    LabeledContent("Notifications and Privacy") {
                        Button("Customize…") { openNotifications(details.conversation.id) }
                    }
                }
            }
            leaving
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private var status: some View {
        if let error = state.browser.panelError {
            Section {
                SheetErrorRow(message: error)
                if state.browser.needsReconciliation {
                    Button("Reload Details") { actions.details(details.conversation.id, false) }
                }
            }
        }
        if let notice = state.browser.notice {
            Section { Label(notice, systemImage: "info.circle") }
        }
        switch details.membership {
        case .invited:
            Section { Label("You’ve been invited to join this space.", systemImage: "envelope") }
        case .requested:
            Section { Label("Your request to join is waiting for approval.", systemImage: "clock") }
        default:
            EmptyView()
        }
    }

    private var preview: some View {
        Section("Recent Messages") {
            if details.previewMessages.isEmpty {
                Text("There are no recent messages to preview.").foregroundStyle(.secondary)
            }
            ForEach(details.previewMessages, id: \.id) { message in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Display.name(of: message.sender, in: state.directory))
                        .font(.subheadline.weight(.semibold))
                    Text(message.text)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder private var leaving: some View {
        if allows("leave") || allows("deleteSpace") {
            Section {
                if allows("leave") {
                    LabeledContent {
                        Button("Leave…", role: .destructive) { pending = .leave }
                    } label: {
                        Text("Leave \(ConversationDetailsText.kind(details.conversation.kind))")
                        Text("You’ll stop getting its messages.")
                    }
                }
                if allows("deleteSpace") {
                    LabeledContent {
                        Button("Delete…", role: .destructive) { pending = .deleteSpace }
                    } label: {
                        Text("Delete Space")
                        Text("Deletes the space and its messages for everyone.")
                    }
                }
            }
            .disabled(state.browser.needsReconciliation)
        }
    }

    // MARK: Buttons

    private var identityChanged: Bool {
        let renamed = allows("rename") && name != (details.conversation.title ?? "")
        let described = allows("description") && description != (details.description ?? "")
        return renamed || described
    }

    private var canSave: Bool {
        allows("identity") && identityChanged && !state.browser.needsReconciliation
            && (!isSpace || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// The one way in a preview offers, as the default button.
    private var joining: ConversationMutation? {
        [.join, .requestJoin, .acceptInvitation].first { allows($0.action) }
    }

    /// The sheet's own placements: the spinner and Decline Invitation… at the
    /// leading edge, where macOS puts a destructive action in a sheet, and
    /// Cancel and the default button trailing, with Escape and Return.
    @ToolbarContentBuilder private var buttons: some ToolbarContent {
        let declines = allows(ConversationMutation.declineInvitation.action)
        if state.browser.isSubmitting || declines {
            ToolbarItem(placement: .destructiveAction) {
                HStack(spacing: 8) {
                    if state.browser.isSubmitting {
                        ProgressView().controlSize(.small)
                    }
                    if declines {
                        Button("Decline Invitation…") { pending = .declineInvitation }
                    }
                }
            }
        }
        if tab == .about, identityChanged {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: actions.closePanel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!canSave)
            }
        } else if let joining {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: actions.closePanel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(ConversationDetailsText.joinTitle(joining)) { actions.mutate(joining) }
                    .disabled(state.browser.needsReconciliation)
            }
        } else {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: actions.closePanel)
            }
        }
    }

    private func save() {
        guard canSave else { return }
        actions.mutate(.identity(
            name: allows("rename") ? name : nil,
            description: allows("description") ? description : nil,
            access: nil
        ))
    }
}

/// The sheet's words, apart from its layout.
enum ConversationDetailsText {
    static func kind(_ kind: Conversation.Kind) -> String {
        switch kind {
        case .space: "Space"
        case .groupDirectMessage: "Group Chat"
        case .appDirectMessage: "App"
        case .meetChat: "Meet Chat"
        default: "Conversation"
        }
    }

    static func subtitle(_ details: ConversationDetails) -> String {
        var parts = [kind(details.conversation.kind)]
        switch details.membership {
        case .joined:
            if let members = Display.memberCountLabel(of: details.conversation) {
                parts.append(members)
            }
        case .invited: parts.append("Invited")
        case .requested: parts.append("Request pending")
        default: parts.append("Not joined")
        }
        return parts.joined(separator: " · ")
    }

    static func joinTitle(_ mutation: ConversationMutation) -> String {
        switch mutation {
        case .requestJoin: "Ask to Join"
        case .acceptInvitation: "Accept Invitation"
        default: "Join Space"
        }
    }

    static func role(_ role: ConversationRole) -> String {
        switch role {
        case .owner: "Owner"
        case .manager: "Manager"
        case .member: "Member"
        default: "Unknown Role"
        }
    }

    @MainActor
    static func confirmationTitle(
        _ mutation: ConversationMutation,
        details: ConversationDetails,
        state: ChatSceneState
    ) -> String {
        let title = Display.title(of: details.conversation, directory: state.directory, me: state.me)
        switch mutation {
        case .leave: return "Leave “\(title)”?"
        case .deleteSpace: return "Delete “\(title)”?"
        case .declineInvitation: return "Decline the invitation to “\(title)”?"
        case let .removePerson(id):
            return "Remove \(Display.name(of: id, in: people(state))) from “\(title)”?"
        case let .rejectRequest(id):
            return "Reject \(Display.name(of: id, in: people(state)))’s request to join?"
        default: return "Change “\(title)”?"
        }
    }

    static func confirmationMessage(_ mutation: ConversationMutation) -> String {
        switch mutation {
        case .leave: "You’ll stop getting its messages. To come back, you’ll need to join or be added again."
        case .deleteSpace: "The space and all of its messages are deleted for everyone. This can’t be undone."
        case .declineInvitation: "The space won’t appear in your list."
        case .removePerson: "They’ll stop getting its messages."
        default: "They won’t be added."
        }
    }

    static func confirmationButton(_ mutation: ConversationMutation) -> String {
        switch mutation {
        case .leave: "Leave"
        case .deleteSpace: "Delete"
        case .declineInvitation: "Decline"
        case .removePerson: "Remove"
        default: "Reject"
        }
    }

    /// Participants' names as well as the directory's, for confirmations
    /// about people the directory may not know yet.
    @MainActor
    private static func people(_ state: ChatSceneState) -> [Member.ID: Member] {
        var people = state.directory
        for participant in state.browser.participants {
            people[participant.id] = participant.member
        }
        return people
    }
}
