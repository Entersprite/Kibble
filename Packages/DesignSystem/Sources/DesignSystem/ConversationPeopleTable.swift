import ChatKit
import SwiftUI

/// Info's People section: a search field that fills the bar, the scope
/// switcher, Copy Member Emails and Add People…, then a sortable,
/// multi-select table of the people loaded so far, with a count below it
/// that says when not every page is loaded.
///
/// Its actions come from each row's `allowedActions` and `allowedRoles`;
/// with several rows selected, only those every row allows. Role changes and
/// approvals apply at once. Remove, Block, Decline and Cancel Invitation
/// ask first.
struct ConversationPeopleTable: View {
    let details: ConversationDetails
    let state: ChatSceneState
    let actions: ConversationBrowserActions

    @State var query = ""
    @State var scope = PeopleScope.members
    @State var selection = Set<Member.ID>()
    @State var sortOrder = [KeyPathComparator(\ConversationParticipant.sortName)]
    @State var confirming: PeopleConfirmation?
    @State var addingPeople = false
    /// The scope Copy Member Emails copies once every page is loaded.
    @State var copyWhenLoaded: PeopleScope?
    @State var copyLoadStarted = false
    @State var copyReport: String?

    var model: PeopleTableModel {
        PeopleTableModel(
            participants: state.browser.participants,
            hasMore: state.browser.hasMoreParticipants,
            memberCount: details.conversation.memberCount,
            isComplete: state.browser.panelError == nil,
            canMessage: state.capabilities.canOpenDirectConversations,
            me: state.me
        )
    }

    /// The chosen scope while it has anyone in it, else Members.
    var shownScope: PeopleScope {
        model.scopes.contains(scope) ? scope : .members
    }

    var rows: [ConversationParticipant] {
        model.rows(scope: shownScope, query: query, sort: sortOrder)
    }

    var isBusy: Bool {
        let browser = state.browser
        return browser.isSubmitting || browser.needsReconciliation || browser.isLoadingAllParticipants
            || browser.isLoadingParticipants
    }

    var body: some View {
        let shown = rows
        VStack(spacing: 0) {
            bar
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            if let copyReport {
                Label(copyReport, systemImage: "info.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
            table(shown)
            Divider()
            footer(shown: shown.count)
        }
        .sheet(isPresented: $addingPeople) { AddPeopleSheet(state: state, actions: actions) }
        .alert(
            confirming?.title ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { shown in
                if !shown {
                    confirming = nil
                }
            }),
            presenting: confirming
        ) { confirmation in
            Button(confirmation.button, role: .destructive) { send(confirmation.mutations) }
            Button(confirmation.keep, role: .cancel) {}
        } message: { confirmation in
            if let message = confirmation.message {
                Text(message)
            }
        }
        .onChange(of: shownScope) { selection = [] }
        .onChange(of: query) { selection.formIntersection(rows.map(\.id)) }
        .onChange(of: state.accountID) { forget() }
        .task(id: copyWatch) { await advanceCopy() }
    }

    // MARK: Bar

    /// How much of the bar fits: compact draws Copy Member Emails and Add
    /// People… as symbols, and narrow, for a sheet at its smallest, also
    /// turns the scope switcher into a pop-up button.
    enum BarFit { case full, compact, narrow }

    /// One search field, so resizing never takes its focus; only the
    /// controls after it change with the width.
    private var bar: some View {
        HStack(spacing: 8) {
            if details.conversation.kind != .directMessage {
                TextField("Search People", text: $query, prompt: Text("Search"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(minWidth: 140, maxWidth: .infinity)
            } else {
                Spacer()
            }
            ViewThatFits(in: .horizontal) {
                barControls(.full)
                barControls(.compact)
                barControls(.narrow)
            }
            .layoutPriority(1)
        }
    }

    private func barControls(_ fit: BarFit) -> some View {
        let compact = fit != .full
        return HStack(spacing: 8) {
            if model.scopes.count > 1 {
                if fit == .narrow {
                    scopePicker.pickerStyle(.menu).fixedSize()
                } else {
                    scopePicker.pickerStyle(.segmented).fixedSize()
                }
            }
            copyButton(compact: compact)
            if details.conversation.kind != .directMessage, details.allowedActions.contains("addPeople") {
                Button {
                    addingPeople = true
                } label: {
                    Label("Add People…", systemImage: "person.badge.plus")
                        .labelStyle(.adaptive(iconOnly: compact))
                }
                .help("Add People")
                .fixedSize()
            }
        }
    }

    private var scopePicker: some View {
        Picker("Show", selection: $scope) {
            ForEach(model.scopes, id: \.self) { scope in
                Text(title(of: scope)).tag(scope)
            }
        }
        .labelsHidden()
    }

    private func title(of scope: PeopleScope) -> String {
        let count = model.rows(scope: scope, query: "", sort: []).count
        switch scope {
        case .members: return "Members"
        case .invited: return "Invited \(count)"
        case .requests: return "Requests \(count)"
        }
    }

    private func copyButton(compact: Bool) -> some View {
        Button {
            copyEmails()
        } label: {
            if copyWhenLoaded != nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Cancel Copy")
                }
            } else {
                Label("Copy Member Emails", systemImage: DirectoryMenuSymbols.copy)
                    .labelStyle(.adaptive(iconOnly: compact))
            }
        }
        .help(copyWhenLoaded == nil ? "Copy Member Emails" : "Stop waiting to copy")
        .disabled(copyWhenLoaded == nil && !canCopy)
        .fixedSize()
    }

    /// Someone to copy, and, with pages left, a model that will load them:
    /// it refuses while a change is on its way or unconfirmed.
    private var canCopy: Bool {
        let browser = state.browser
        let refused = browser.hasMoreParticipants && (browser.isSubmitting || browser.needsReconciliation)
        return !refused && !model.rows(scope: shownScope, query: "", sort: []).isEmpty
    }

    // MARK: Table

    private func table(_ rows: [ConversationParticipant]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.sortName) { participant in
                nameCell(participant)
            }
            .width(min: 120, ideal: 170)
            TableColumn("Email", value: \.sortEmail) { participant in
                Text(participant.member.email ?? "")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(participant.member.email ?? "")
            }
            .width(min: 100, ideal: 140)
            TableColumn("Role", value: \.roleRank) { participant in
                roleCell(participant)
            }
            .width(min: 90, ideal: 120)
        }
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.enabled)
        .contextMenu(forSelectionType: Member.ID.self) { ids in
            menu(for: ids.intersection(rows.map(\.id)))
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first, model.commands(for: ids).contains(.message) {
                message(id)
            }
        }
        .overlay { emptyState(rows) }
    }

    private func nameCell(_ participant: ConversationParticipant) -> some View {
        HStack(spacing: 8) {
            Avatar(member: participant.id, directory: [participant.id: participant.member], size: 22)
                .besideName()
            Text(participant.sortName).lineLimit(1)
            if participant.isExternal == true {
                PeopleTag(title: "External", tint: .orange)
            }
            if participant.isBlocked == true {
                PeopleTag(title: "Blocked", tint: .secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PeopleConfirmation.rowLabel(participant))
    }

    @ViewBuilder private func roleCell(_ participant: ConversationParticipant) -> some View {
        if case let .setRole(id, role) = state.browser.pendingMutation, id == participant.id {
            HStack(spacing: 6) {
                Text(ConversationDetailsText.role(role)).foregroundStyle(.secondary)
                ProgressView().controlSize(.mini)
            }
            .accessibilityElement(children: .combine)
        } else if PeopleScope.of(participant) == .requests {
            requestButtons(participant)
        } else {
            Text(PeopleConfirmation.roleText(participant) ?? "")
        }
    }

    /// Decline and Approve, as words, or as symbols when the column is narrow.
    private func requestButtons(_ participant: ConversationParticipant) -> some View {
        ViewThatFits(in: .horizontal) {
            requestButtons(participant, iconOnly: false)
            requestButtons(participant, iconOnly: true)
        }
        .controlSize(.small)
        .disabled(isBusy)
    }

    private func requestButtons(_ participant: ConversationParticipant, iconOnly: Bool) -> some View {
        let name = participant.sortName
        return HStack(spacing: 6) {
            if participant.allowedActions.contains("rejectRequest") {
                Button { confirm(.reject, ids: [participant.id]) } label: {
                    Label("Decline", systemImage: "xmark").labelStyle(.adaptive(iconOnly: iconOnly))
                }
                .buttonStyle(.bordered)
                .help("Decline")
                .accessibilityLabel("Decline \(name)")
            }
            if participant.allowedActions.contains("approveRequest") {
                // Prominent without a key: Return stays the sheet's Done.
                Button { send([.approveRequest(participant.id)]) } label: {
                    Label("Approve", systemImage: "checkmark").labelStyle(.adaptive(iconOnly: iconOnly))
                }
                .buttonStyle(.borderedProminent)
                .help("Approve")
                .accessibilityLabel("Approve \(name)")
            }
        }
        .fixedSize()
    }

    @ViewBuilder private func emptyState(_ rows: [ConversationParticipant]) -> some View {
        if rows.isEmpty {
            switch PeopleListStatus.of(state.browser) {
            case .loading:
                ProgressView()
            case .failed:
                // The header says why; this offers the way on.
                ContentUnavailableView {
                    Label("Couldn’t Load People", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("Try Again") { actions.details(details.conversation.id, false) }
                }
            case .ready:
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }

    // MARK: Footer

    /// Nobody to count yet: a count of zero would say the list is empty.
    private var isFirstPageLoading: Bool {
        state.browser.participants.isEmpty && PeopleListStatus.of(state.browser) == .loading
    }

    private func footer(shown: Int) -> some View {
        HStack(spacing: 8) {
            Text(isFirstPageLoading ? "Loading people…" : model.countText(scope: shownScope, shown: shown))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if state.browser.isLoadingParticipants || state.browser.isLoadingAllParticipants {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 8)
            if state.browser.hasMoreParticipants {
                let available = PeopleListStatus.canLoadMore(state.browser)
                Button("Load More") { actions.details(details.conversation.id, true) }
                    .disabled(!available)
                Button("Load All", action: actions.loadAllParticipants)
                    .disabled(!available)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

/// A small tag beside a person's name, such as External.
struct PeopleTag: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.16), in: .rect(cornerRadius: 4))
            .fixedSize()
    }
}

private extension LabelStyle where Self == AdaptiveLabelStyle {
    static func adaptive(iconOnly: Bool) -> AdaptiveLabelStyle {
        AdaptiveLabelStyle(iconOnly: iconOnly)
    }
}

/// Title and icon, or the icon alone when space is short.
struct AdaptiveLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            Label(configuration).labelStyle(.iconOnly)
        } else {
            Label(configuration).labelStyle(.titleOnly)
        }
    }
}
