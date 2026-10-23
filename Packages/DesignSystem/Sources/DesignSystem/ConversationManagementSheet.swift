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
