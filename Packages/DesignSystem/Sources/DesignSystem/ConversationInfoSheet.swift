import ChatKit
import SwiftUI

/// What the section holding unsaved edits offers the sheet.
///
/// This is the seam a section with a draft plugs into. The sheet hands each
/// section `draft`, a `Binding<InfoSectionDraft?>`. While the section has
/// unsaved edits it writes one of these (for example from
/// `.onChange(of: localDraft, initial: true)`), and nil again once it is clean,
/// saved or reverted. The sheet derives its `InfoDraftState` from it, draws the
/// sidebar dot, swaps Done for Revert and Save, and asks before leaving.
/// `save` is what Save sends, in the footer or in the leave alert: that one
/// section's request and nothing else.
///
/// The sheet offers Save only while the draft is valid and the model can take
/// a write: not while reconciling, loading every participant or submitting,
/// because `mutate` drops a write then without a word. If a Save still never
/// starts submitting, the sheet forgets the switch or close waiting on it, so
/// `save` may simply return when the section has nothing to send.
struct InfoSectionDraft {
    let section: InfoSection
    /// False while the draft can't be sent (an empty space name, a field over its limit).
    var isValid: Bool
    var save: () -> Void
    var revert: () -> Void
}

/// A joined conversation's Info: a resizable sheet with a sidebar of the
/// sections the conversation has, the conversation's picture, name and kind
/// above every section, and the sheet's own buttons below.
///
/// Only the current section can hold unsaved edits. Switching sections or
/// closing with a draft asks Save / Don't Save / Cancel first.
struct ConversationInfoSheet: View {
    let details: ConversationDetails
    let state: ChatSceneState
    let actions: ConversationBrowserActions
    /// The window's actions, for the pickers sections borrow (the emoji picker's reactions).
    let media: ChatSceneActions?
    let openNotifications: ((Conversation.ID) -> Void)?

    static let minimum = CGSize(width: 640, height: 440)
    /// The size the person last left the sheet at, offered when it opens again.
    @AppStorage("conversationInfo.width") private var width = 760.0
    @AppStorage("conversationInfo.height") private var height = 560.0
    @State private var selection = InfoSection.people
    @State private var drafts = InfoDraftState()
    @State private var draft: InfoSectionDraft?
    /// The request the leave alert is asking about.
    @State private var asking: InfoDraftState.Request?
    /// The section shows the panel's error beside what failed; the header doesn't repeat it.
    @State private var errorShownInline = false

    init(
        details: ConversationDetails,
        state: ChatSceneState,
        actions: ConversationBrowserActions,
        media: ChatSceneActions?,
        openNotifications: ((Conversation.ID) -> Void)?,
        // The section it opens on: People, except in renders of another section.
        section: InfoSection = .people,
        draft: InfoSectionDraft? = nil
    ) {
        self.details = details
        self.state = state
        self.actions = actions
        self.media = media
        self.openNotifications = openNotifications
        _selection = State(initialValue: section)
        // A draft already reported when the sheet opens; tests start dirty with it.
        _draft = State(initialValue: draft)
        _drafts = State(initialValue: InfoDraftState(dirtySection: draft?.section))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            section
                .safeAreaBar(edge: .top) { header }
                .scrollEdgeEffectStyle(.soft, for: .vertical)
        }
        .frame(
            minWidth: Self.minimum.width, idealWidth: idealSize.width, maxWidth: .infinity,
            minHeight: Self.minimum.height, idealHeight: idealSize.height, maxHeight: .infinity
        )
        .presentationSizing(.fitted)
        // Info usually replaces Loading in a sheet already shown, which
        // SwiftUI neither grows nor makes resizable; this sizes the window.
        .sheetWindowSizing(minimum: Self.minimum, ideal: idealSize) { size in
            width = size.width
            height = size.height
        }
        .toolbar { footer }
        .interactiveDismissDisabled(drafts.dirtySection != nil || state.browser.isSubmitting)
        .onExitCommand { go(.close) }
        .onChange(of: state.browser.isSubmitting) { _, submitting in
            if submitting {
                drafts.submissionStarted()
            }
        }
        .task(id: drafts.afterSave) {
            // A refused write never starts submitting; stop waiting on it.
            guard drafts.afterSave != nil else { return }
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled {
                drafts.saveMustHaveStarted()
            }
        }
        .onChange(of: state.browser.panelError) { _, error in
            // The save the alert sent failed: stay, with the draft and the reason.
            if error != nil {
                drafts.stopWaiting()
            }
        }
        .alert(
            asking.map { _ in "Save changes to \(drafts.dirtySection?.title ?? "")?" } ?? "",
            isPresented: Binding(get: { asking != nil }, set: { shown in
                if !shown {
                    asking = nil
                }
            }),
            presenting: asking
        ) { request in
            Button("Save") {
                drafts.save(then: request)
                draft?.save()
            }
            .disabled(!canSave)
            Button("Don’t Save", role: .destructive) {
                draft?.revert()
                perform(request)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var idealSize: CGSize {
        CGSize(width: max(width, Self.minimum.width), height: max(height, Self.minimum.height))
    }

    // MARK: Sections

    private var sections: [InfoSection] {
        let browser = state.browser
        return ConversationInfoSections.available(
            for: details,
            capabilities: state.capabilities,
            hasParticipants: !browser.participants.isEmpty || browser.isLoadingParticipants
                || browser.hasMoreParticipants
        )
    }

    /// The selected section, or the first there is when the selected one
    /// isn't offered (a meet chat with no participant list opens on Details).
    /// Every kind has at least one section.
    private var shown: InfoSection {
        sections.contains(selection) ? selection : sections.first ?? .details
    }

    private var sidebar: some View {
        List(selection: Binding<InfoSection?>(get: { shown }, set: { section in
            if let section, section != shown {
                go(.switchTo(section))
            }
        })) {
            ForEach(sections, id: \.self) { section in
                Label {
                    HStack {
                        Text(section.title)
                        Spacer(minLength: 4)
                        if drafts.dirtySection == section {
                            Circle()
                                .fill(.tint)
                                .frame(width: 7, height: 7)
                                .accessibilityLabel("Unsaved changes")
                        }
                    }
                } icon: {
                    Image(systemName: section.systemImage)
                }
                .tag(section)
            }
        }
        .listStyle(.sidebar)
    }

    /// Each section's view. A section with a draft gets `draftBinding`.
    /// People and Integrations have none: their changes apply at once.
    @ViewBuilder private var section: some View {
        switch shown {
        case .people:
            ConversationPeopleTable(details: details, state: state, actions: actions)
        case .details:
            ConversationDetailsForm(
                details: details, state: state, actions: actions, reactions: media?.reactions,
                openNotifications: openNotifications, report: draftBinding
            )
            // The draft belongs to one account's conversation; two accounts can share a space.
            .id(AccountScoped(account: state.accountID, value: details.conversation.id))
        case .settings:
            ConversationSettingsForm(details: details, state: state, actions: actions, report: draftBinding)
                .id(AccountScoped(account: state.accountID, value: details.conversation.id))
        case .integrations:
            // No draft: each change is sent on its own.
            ConversationIntegrationsForm(
                details: details, state: state, actions: actions, showsErrorInline: $errorShownInline
            )
            .id(AccountScoped(account: state.accountID, value: details.conversation.id))
        }
    }

    /// What a section reports its draft through (see `InfoSectionDraft`).
    private var draftBinding: Binding<InfoSectionDraft?> {
        Binding(get: { draft }, set: { report($0) })
    }

    private func report(_ next: InfoSectionDraft?) {
        draft = next
        if let request = drafts.report(dirty: next?.section) {
            perform(request)
        }
    }

    /// Whether Save can start a write now. `mutate` returns without a word
    /// while reconciling, loading every participant or submitting.
    private var canSave: Bool {
        let browser = state.browser
        return draft?.isValid == true && !browser.needsReconciliation
            && !browser.isLoadingAllParticipants && !browser.isSubmitting
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            SheetHeader(title: title, message: ConversationDetailsText.subtitle(details)) {
                ConversationPicture(
                    conversation: details.conversation,
                    directory: state.directory,
                    me: state.me,
                    size: 40
                )
            }
            if let error = state.browser.panelError {
                if !errorShownInline {
                    panelErrorRow(error)
                }
            } else if let notice = state.browser.notice {
                Label(notice, systemImage: "info.circle")
                    .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 8)
    }

    private func panelErrorRow(_ error: String) -> some View {
        HStack {
            SheetErrorRow(message: error)
            Spacer(minLength: 8)
            if state.browser.needsReconciliation {
                Button("Reload Details") { actions.details(details.conversation.id, false) }
            }
        }
        .padding(.horizontal, 20)
    }

    private var title: String {
        Display.title(of: details.conversation, directory: state.directory, me: state.me)
    }

    // MARK: Footer

    /// The sheet's own placements: Return is Done or Save, and the leading
    /// edge says why. Escape always goes through `go(.close)`, which asks
    /// first when there is a draft. Revert sits in the cancellation slot
    /// beside Save but has its Escape removed: with it, Escape would discard
    /// the draft without asking.
    @ToolbarContentBuilder private var footer: some ToolbarContent {
        if draft != nil || state.browser.isSubmitting {
            ToolbarItem(placement: .destructiveAction) {
                HStack(spacing: 8) {
                    if state.browser.isSubmitting {
                        ProgressView().controlSize(.small)
                    }
                    if draft != nil {
                        Text("Unsaved changes").foregroundStyle(.secondary)
                    }
                }
            }
        }
        if let draft {
            // Beside Save, but with no key: Escape stays with `go(.close)`.
            ToolbarItem(placement: .cancellationAction) {
                Button("Revert") {
                    drafts.stopWaiting()
                    draft.revert()
                }
                .keyboardShortcut(nil)
                .disabled(state.browser.isSubmitting)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: draft.save)
                    .disabled(!canSave)
            }
        } else {
            ToolbarItem(placement: .confirmationAction) {
                // The model refuses to close while a write is on its way.
                Button("Done") { go(.close) }
                    .disabled(state.browser.isSubmitting)
            }
        }
    }

    // MARK: Leaving a draft

    private func go(_ request: InfoDraftState.Request) {
        switch drafts.request(request) {
        case let .proceed(request): perform(request)
        case let .askToSave(request): asking = request
        }
    }

    /// Goes ahead with a request whose draft was saved, discarded or never there.
    private func perform(_ request: InfoDraftState.Request) {
        switch request {
        case let .switchTo(section):
            if draft?.section != section {
                report(nil)
            }
            selection = section
        case .close:
            // The model refuses while a write is in flight; the sheet then stays as it was.
            actions.closePanel()
        }
    }
}
