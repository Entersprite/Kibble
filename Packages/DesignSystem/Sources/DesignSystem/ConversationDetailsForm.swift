import ChatKit
import SwiftUI

/// Info's Details: a space's emoji, name, description and guidelines; a
/// group chat's name and Convert to Space…; other kinds' name as text. Below
/// them, Notifications and Privacy, Leave… and Delete Space.
///
/// Edits are a draft until the sheet's Save. The form reports the draft
/// through `report` (see `InfoSectionDraft`), and Save sends one details
/// patch with only the changed fields. A field the server doesn't allow is
/// text, not a field.
struct ConversationDetailsForm: View {
    let details: ConversationDetails
    let state: ChatSceneState
    let actions: ConversationBrowserActions
    /// The emoji picker's source. Without it there is no Choose Emoji….
    let reactions: ReactionActions?
    let openNotifications: ((Conversation.ID) -> Void)?
    @Binding var report: InfoSectionDraft?

    @State private var draft: DetailsDraft
    /// Save was sent: the next `details` is its answer, so the draft starts over from it.
    @State private var saving = false
    @State private var pickingEmoji = false
    @State private var pending: ConversationMutation?
    /// Seam: Convert to Space… presents `ConvertToSpaceSeam` until the
    /// conversion sheet replaces it.
    @State private var converting = false

    init(
        details: ConversationDetails,
        state: ChatSceneState,
        actions: ConversationBrowserActions,
        reactions: ReactionActions?,
        openNotifications: ((Conversation.ID) -> Void)?,
        report: Binding<InfoSectionDraft?>
    ) {
        self.details = details
        self.state = state
        self.actions = actions
        self.reactions = reactions
        self.openNotifications = openNotifications
        _report = report
        _draft = State(initialValue: DetailsDraft(details))
    }

    var body: some View {
        Form {
            Group {
                switch details.conversation.kind {
                case .space: spaceFields
                case .groupDirectMessage: groupFields
                default: Section { LabeledContent("Name", value: title) }
                }
            }
            .disabled(state.browser.isSubmitting)
            notifications
            leaving
        }
        .formStyle(.grouped)
        .onChange(of: details) { _, details in
            // A reload keeps what was typed; the saved answer starts over, so
            // a value the server tidied up doesn't stay an edit.
            draft = saving ? DetailsDraft(details) : draft.rebased(onto: details)
            saving = false
        }
        .onChange(of: state.browser.panelError) { _, error in
            if error != nil {
                saving = false
            }
        }
        .onChange(of: reportKey, initial: true) { publish() }
        .sheet(isPresented: $converting) { ConvertToSpaceSeam() }
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

    private var title: String {
        Display.title(of: details.conversation, directory: state.directory, me: state.me)
    }

    private func allows(_ action: String) -> Bool {
        details.allowedActions.contains(action)
    }

    // MARK: Fields

    @ViewBuilder private var spaceFields: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                emojiTile
                VStack(alignment: .leading, spacing: 6) {
                    if draft.canEdit(.name) {
                        // Bordered: beside the tile, a plain field reads as a label.
                        TextField("Name", text: $draft.name, prompt: Text("Required"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                    } else {
                        Text(title).font(.headline)
                    }
                    HStack(spacing: 8) {
                        if draft.canEdit(.emoji) {
                            emojiButtons
                        }
                        Spacer(minLength: 8)
                        if draft.canEdit(.name) {
                            counter(draft.name, .name)
                        }
                    }
                }
            }
        }
        textSection("Description", text: $draft.description, field: .description, lines: 2 ... 6)
        textSection("Guidelines", text: $draft.guidelines, field: .guidelines, lines: 3 ... 10)
    }

    /// The name, then Convert to Space… below it when allowed.
    @ViewBuilder private var groupFields: some View {
        Section {
            if draft.canEdit(.name) {
                TextField("Name", text: $draft.name, prompt: Text("Optional"))
            } else {
                LabeledContent("Name", value: title)
            }
        } footer: {
            if draft.canEdit(.name) {
                counter(draft.name, .name).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        if allows("convertToSpace") {
            Section {
                Button("Convert to Space…") { converting = true }
                    .disabled(state.browser.needsReconciliation)
            }
        }
    }

    /// A multi-line field with its counter, or its text when it can't be changed.
    @ViewBuilder private func textSection(
        _ label: String,
        text: Binding<String>,
        field: DetailsDraft.Field,
        lines: ClosedRange<Int>
    ) -> some View {
        if draft.canEdit(field) {
            Section {
                TextField(label, text: text, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(lines)
                    .labelsHidden()
            } header: {
                Text(label)
            } footer: {
                counter(text.wrappedValue, field).frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else if !text.wrappedValue.isEmpty {
            Section {
                LabeledContent(label) {
                    Text(text.wrappedValue)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// "n / limit" in UTF-16 units, red past the server's limit. No limit, no counter.
    @ViewBuilder private func counter(_ text: String, _ field: DetailsDraft.Field) -> some View {
        if let limit = draft.limit(field.rawValue) {
            let length = DetailsDraft.length(text)
            Text("\(length) / \(limit.formatted())")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(length > limit ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .accessibilityLabel("\(length) of \(limit) characters")
        }
    }

    // MARK: Emoji

    private var canChooseEmoji: Bool {
        draft.canEdit(.emoji) && reactions != nil
    }

    @ViewBuilder private var emojiTile: some View {
        if canChooseEmoji {
            Button { pickingEmoji = true } label: { tile }
                .buttonStyle(.plain)
                .help("Choose Emoji")
                .accessibilityLabel(draft.emoji
                    .flatMap { $0.isEmpty ? nil : "Emoji \($0)" } ?? "Default Icon")
                .popover(isPresented: $pickingEmoji, arrowEdge: .bottom) {
                    if let reactions {
                        EmojiPicker(reactions: [], actions: reactions, use: .text) { choice, _ in
                            draft.emoji = choice.emoji
                            pickingEmoji = false
                        }
                    }
                }
        } else {
            tile.accessibilityHidden(true)
        }
    }

    /// The chosen emoji, or the conversation's own picture.
    @ViewBuilder private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        if let emoji = draft.emoji, !emoji.isEmpty {
            shape.fill(.quaternary)
                .overlay { Text(emoji).font(.system(size: 26)) }
                .frame(width: 44, height: 44)
        } else {
            // Use Default Icon was chosen: not the emoji's picture any more.
            let picture = details.settings?.emoji?.isEmpty == false
                ? Conversation(id: details.conversation.id, kind: .space, title: draft.name)
                : details.conversation
            ConversationPicture(conversation: picture, directory: state.directory, me: state.me, size: 44)
        }
    }

    private var emojiButtons: some View {
        HStack(spacing: 6) {
            if reactions != nil {
                Button("Choose Emoji…") { pickingEmoji = true }
            }
            Button("Use Default Icon") { draft.emoji = "" }
                .disabled((draft.emoji ?? "").isEmpty)
        }
        .controlSize(.small)
    }

    // MARK: Below the fields

    @ViewBuilder private var notifications: some View {
        if let openNotifications {
            Section {
                LabeledContent("Notifications and Privacy") {
                    // Opening them closes Info, which would drop the draft unasked.
                    Button("Customize…") { openNotifications(details.conversation.id) }
                        .disabled(draft.isDirty)
                        .help(
                            draft.isDirty
                                ? "Save or revert your changes first."
                                : "Choose how this conversation notifies you."
                        )
                }
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
            .disabled(state.browser.needsReconciliation || state.browser.isSubmitting)
        }
    }

    // MARK: Reporting the draft

    /// What the sheet's copy of the draft depends on: its closures read the
    /// browser's flags and `details` as they were when it was made.
    private var reportKey: ReportKey {
        let browser = state.browser
        return ReportKey(
            details: details, isDirty: draft.isDirty, isValid: draft.isValid,
            blocked: browser.needsReconciliation || browser.isLoadingAllParticipants || browser.isSubmitting
        )
    }

    private struct ReportKey: Equatable {
        let details: ConversationDetails
        let isDirty: Bool
        let isValid: Bool
        let blocked: Bool
    }

    private func publish() {
        guard draft.isDirty else {
            if report != nil {
                report = nil
            }
            return
        }
        let blocked = reportKey.blocked
        let details = details
        report = InfoSectionDraft(
            section: .details,
            isValid: draft.isValid,
            save: {
                // The model drops a write while reconciling, loading or submitting.
                guard !blocked, draft.isValid, let patch = draft.patch() else { return }
                saving = true
                actions.mutate(.details(patch))
            },
            revert: { draft = DetailsDraft(details) }
        )
    }
}

/// Seam: stands in for the Convert to Space sheet, which replaces it.
struct ConvertToSpaceSeam: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Label("Convert to Space", systemImage: "arrow.up.forward.square")
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 140)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}
