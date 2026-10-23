import ChatKit
import SwiftUI

/// Info's Settings, for a space: who can find and join it, who can do what
/// in it, and its email address.
///
/// Access and Who Can are one draft until the sheet's Save, which sends one
/// settings patch with only what changed (see `SettingsDraft`). A rule or
/// mode the server doesn't let this person change, or that Kibble can't
/// represent, is text. Space Email acts at once and is not part of the draft.
struct ConversationSettingsForm: View {
    let details: ConversationDetails
    let state: ChatSceneState
    let actions: ConversationBrowserActions
    @Binding var report: InfoSectionDraft?

    @State private var draft: SettingsDraft

    init(
        details: ConversationDetails,
        state: ChatSceneState,
        actions: ConversationBrowserActions,
        report: Binding<InfoSectionDraft?>
    ) {
        self.details = details
        self.state = state
        self.actions = actions
        _report = report
        _draft = State(initialValue: SettingsDraft(details))
    }

    var body: some View {
        Form {
            Group {
                access
                whoCan
            }
            .disabled(state.browser.isSubmitting)
            if state.capabilities.canManageConversationEmail {
                SpaceEmailSection(spaceName: title, state: state, actions: actions)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if state.capabilities.canManageConversationEmail {
                actions.loadEmail()
            }
        }
        .reportsInfoDraft(
            InfoDraftSeam(
                section: .settings, isDirty: draft.isDirty,
                mutation: { draft.patch().map(ConversationMutation.settings) },
                revert: { draft = SettingsDraft(details) },
                update: { details, isAnswer in draft = draft.updated(to: details, isAnswer: isAnswer) }
            ),
            details: details, state: state, actions: actions, report: $report
        )
    }

    private var title: String {
        Display.title(of: details.conversation, directory: state.directory, me: state.me)
    }

    // MARK: Who Can Find and Join

    private var access: some View {
        Section("Who Can Find and Join") {
            if draft.canChangeAccess {
                Picker("Access", selection: $draft.access) {
                    ForEach(SettingsDraft.accessModes, id: \.self) { mode in
                        accessLabel(mode).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            } else {
                LabeledContent("Access") {
                    Text(PermissionText.access(draft.access))
                }
                .help(
                    PermissionText.accessExplanation(draft.access) ?? "This setting can’t be changed here."
                )
            }
            // Open offers no requests to join.
            if draft.requestToJoin != nil, !draft.isOpen {
                Toggle("Allow requests to join", isOn: Binding(
                    get: { draft.requestToJoin ?? false },
                    set: { draft.requestToJoin = $0 }
                ))
                .disabled(!draft.canChangeRequestToJoin)
            }
            if let external = details.settings?.externalMembersAllowed {
                LabeledContent("External people") {
                    Text("\(external ? "Allowed" : "Not allowed") · set when the space was created")
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private func accessLabel(_ mode: ConversationAccess) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(PermissionText.access(mode))
            if let explanation = PermissionText.accessExplanation(mode) {
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Who Can

    /// The rules Kibble has words for; any other stays as it is, unshown.
    private var labeled: [(label: String, permission: ConversationPermission)] {
        draft.permissions.compactMap { permission in
            PermissionText.label(permission.id).map { ($0, permission) }
        }
    }

    @ViewBuilder private var whoCan: some View {
        let rows = labeled
        if !rows.isEmpty {
            Section("Who Can") {
                ForEach(rows, id: \.permission.id) { row in
                    rule(row.label, row.permission)
                }
            }
        }
    }

    @ViewBuilder private func rule(_ label: String, _ permission: ConversationPermission) -> some View {
        let choices = draft.choices(for: permission.id)
        if draft.isReadOnly(permission) || choices.isEmpty {
            LabeledContent(label) {
                Text(PermissionText.audience(permission.audience))
            }
            .help("This rule can’t be changed here.")
        } else {
            Picker(label, selection: Binding(
                get: { draft.audiences[permission.id] ?? permission.audience },
                set: { draft.setAudience($0, for: permission.id) }
            )) {
                ForEach(choices, id: \.self) { audience in
                    Text(PermissionText.audience(audience)).tag(audience)
                }
            }
            .pickerStyle(.menu)
        }
    }
}
