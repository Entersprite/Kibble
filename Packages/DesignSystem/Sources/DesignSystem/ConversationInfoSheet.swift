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

    /// The last size, offered as the sheet's ideal size when it opens again.
    @AppStorage("conversationInfo.width") private var width = 760.0
    @AppStorage("conversationInfo.height") private var height = 560.0
    /// The remembered size this presentation opened with.
    @State private var opening: CGSize?
    @State private var selection = InfoSection.people
    @State private var drafts = InfoDraftState()
    @State private var draft: InfoSectionDraft?
    /// The request the leave alert is asking about.
    @State private var asking: InfoDraftState.Request?
    /// A request that goes ahead once the alert's Save has landed and the section is clean.
    @State private var afterSave: InfoDraftState.Request?

    init(
        details: ConversationDetails,
        state: ChatSceneState,
        actions: ConversationBrowserActions,
        media: ChatSceneActions?,
        openNotifications: ((Conversation.ID) -> Void)?
    ) {
        self.details = details
        self.state = state
        self.actions = actions
        self.media = media
        self.openNotifications = openNotifications
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
            minWidth: 640, idealWidth: max(idealSize.width, 640), maxWidth: .infinity,
            minHeight: 440, idealHeight: max(idealSize.height, 440), maxHeight: .infinity
        )
        .presentationSizing(.fitted)
        .onGeometryChange(for: CGSize.self, of: \.size) { size in
            // The first layout passes report the minimum. Hold the opening
            // size before saving, so the sheet doesn't shrink to what it reports.
            if opening == nil {
                opening = CGSize(width: width, height: height)
            }
            width = size.width
            height = size.height
        }
        .toolbar { footer }
        .interactiveDismissDisabled(drafts.dirtySection != nil || state.browser.isSubmitting)
        .onExitCommand { go(.close) }
        .onChange(of: drafts.dirtySection) { _, dirty in
            if dirty == nil, let next = afterSave {
                afterSave = nil
                perform(next)
            }
        }
        .onChange(of: state.browser.panelError) { _, error in
            // The save the alert sent failed: stay, with the draft and the reason.
            if error != nil {
                afterSave = nil
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
                draft?.save()
                afterSave = request
            }
            .disabled(draft?.isValid != true || state.browser.isSubmitting)
            Button("Don’t Save", role: .destructive) {
                draft?.revert()
                perform(request)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var idealSize: CGSize {
        opening ?? CGSize(width: width, height: height)
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

    /// Each section's view. Placeholders until their own views replace them;
    /// a section with a draft gets `draftBinding`.
    private var section: some View {
        InfoSectionPlaceholder(section: shown)
    }

    /// What a section reports its draft through (see `InfoSectionDraft`).
    private var draftBinding: Binding<InfoSectionDraft?> {
        Binding(get: { draft }, set: { report($0) })
    }

    private func report(_ next: InfoSectionDraft?) {
        draft = next
        drafts.dirtySection = next?.section
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
                HStack {
                    SheetErrorRow(message: error)
                    Spacer(minLength: 8)
                    if state.browser.needsReconciliation {
                        Button("Reload Details") { actions.details(details.conversation.id, false) }
                    }
                }
                .padding(.horizontal, 20)
            } else if let notice = state.browser.notice {
                Label(notice, systemImage: "info.circle")
                    .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 8)
    }

    private var title: String {
        Display.title(of: details.conversation, directory: state.directory, me: state.me)
    }

    // MARK: Footer

    /// The sheet's own placements: Return is Done or Save, Escape is Revert
    /// while there is a draft, and the leading edge says why.
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
            ToolbarItem(placement: .cancellationAction) {
                Button("Revert") {
                    afterSave = nil
                    draft.revert()
                }
                .disabled(state.browser.isSubmitting)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: draft.save)
                    .disabled(!draft.isValid || state.browser.isSubmitting)
            }
        } else {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { go(.close) }
            }
        }
    }

    // MARK: Leaving a draft

    private func go(_ request: InfoDraftState.Request) {
        afterSave = nil
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

/// Stands in for a section until its own view replaces it: People, Details,
/// Settings and Integrations each arrive in a later change.
struct InfoSectionPlaceholder: View {
    let section: InfoSection

    var body: some View {
        Form {
            Section {
                Label(section.title, systemImage: section.systemImage)
            }
        }
        .formStyle(.grouped)
    }
}
