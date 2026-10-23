import ChatKit
import SwiftUI
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// The People table's context menu, confirmations and Copy Member Emails.
extension ConversationPeopleTable {
    // MARK: Menu

    @ViewBuilder func menu(for ids: Set<Member.ID>) -> some View {
        let commands = model.commands(for: ids)
        ForEach(Array(commands.enumerated()), id: \.offset) { index, command in
            if index > 0, Self.group(commands[index - 1]) != Self.group(command) {
                Divider()
            }
            button(command, ids: ids)
        }
    }

    private static func group(_ command: PersonCommand) -> Int {
        switch command {
        case .message: 0
        case .makeRole: 1
        case .copyEmail, .block, .unblock: 2
        case .approve, .reject: 3
        case .remove, .cancelInvitation: 4
        }
    }

    @ViewBuilder private func button(_ command: PersonCommand, ids: Set<Member.ID>) -> some View {
        let several = ids.count > 1
        switch command {
        case .message:
            Button("Message", systemImage: DirectoryMenuSymbols.message) { ids.first.map(message) }
        case let .makeRole(role):
            Button("Make \(ConversationDetailsText.role(role))", systemImage: DirectoryMenuSymbols.setRole) {
                send(ordered(ids).map { .setRole($0, role) })
            }
            .disabled(isBusy)
        case .copyEmail:
            Button("Copy Email", systemImage: DirectoryMenuSymbols.copy) { copyEmail(of: ids) }
        case .block:
            Button("Block…", systemImage: DirectoryMenuSymbols.block) { confirm(.block, ids: ids) }
                .disabled(isBusy)
        case .unblock:
            Button("Unblock", systemImage: DirectoryMenuSymbols.unblock) {
                send(ordered(ids).map { .setPersonBlocked($0, false) })
            }
            .disabled(isBusy)
        case .approve:
            Button(
                several ? "Approve Requests" : "Approve Request", systemImage: DirectoryMenuSymbols.approve
            ) {
                send(ordered(ids).map { .approveRequest($0) })
            }
            .disabled(isBusy)
        case .reject:
            Button(
                several ? "Decline Requests…" : "Decline Request…", systemImage: DirectoryMenuSymbols.reject
            ) {
                confirm(.reject, ids: ids)
            }
            .disabled(isBusy)
        case .cancelInvitation:
            Button(
                several ? "Cancel Invitations…" : "Cancel Invitation…",
                systemImage: DirectoryMenuSymbols.reject, role: .destructive
            ) {
                confirm(.cancelInvitation, ids: ids)
            }
            .disabled(isBusy)
        case .remove:
            Button(
                "Remove from \(ConversationDetailsText.kind(details.conversation.kind))…",
                systemImage: DirectoryMenuSymbols.remove, role: .destructive
            ) {
                confirm(.remove, ids: ids)
            }
            .disabled(isBusy)
        }
    }

    /// The selection in the order the people were loaded, so a batch is predictable.
    private func ordered(_ ids: Set<Member.ID>) -> [Member.ID] {
        model.participants.map(\.id).filter(ids.contains)
    }

    /// Opens a direct message, as the People directory does.
    func message(_ id: Member.ID) {
        guard state.capabilities.canOpenDirectConversations else { return }
        actions.create(ConversationDraft(kind: .directMessage, members: [id]))
    }

    func confirm(_ kind: PeopleConfirmation.Kind, ids: Set<Member.ID>) {
        let people = model.participants.filter { ids.contains($0.id) }
        guard !people.isEmpty else { return }
        confirming = PeopleConfirmation(
            kind: kind, people: people,
            conversation: Display.title(of: details.conversation, directory: state.directory, me: state.me),
            details: details, state: state
        )
    }

    // MARK: Sending

    /// Sends one change, or several one at a time.
    func send(_ mutations: [ConversationMutation]) {
        if let next = queue.start(mutations) {
            actions.mutate(next)
        }
    }

    func submissionChanged(_ submitting: Bool) {
        if submitting {
            queue.submissionStarted()
            return
        }
        let failed = state.browser.panelError != nil || state.browser.needsReconciliation
        if let next = queue.submissionEnded(failed: failed) {
            actions.mutate(next)
        }
    }

    /// Another account's window: nothing chosen here applies there.
    func forget() {
        selection = []
        confirming = nil
        queue = PeopleMutationQueue()
        copyWhenLoaded = nil
        copyReport = nil
        query = ""
    }

    // MARK: Copying

    /// Copies the scope's addresses once every page is loaded, never a
    /// partial list as if it were complete. Again while waiting cancels it.
    func copyEmails() {
        guard copyWhenLoaded == nil else {
            copyWhenLoaded = nil
            return
        }
        copyReport = nil
        guard state.browser.hasMoreParticipants else {
            copy(shownScope)
            return
        }
        copyLoadStarted = state.browser.isLoadingAllParticipants
        copyWhenLoaded = shownScope
        actions.loadAllParticipants()
    }

    func loadingAllChanged(_ loading: Bool) {
        guard let scope = copyWhenLoaded else { return }
        if loading {
            copyLoadStarted = true
            return
        }
        copyWhenLoaded = nil
        if PeopleEmailCopy.canCopyLoaded(state.browser) {
            copy(scope)
        } else {
            copyReport = PeopleEmailCopy.failure
        }
    }

    private func copy(_ scope: PeopleScope) {
        let (emails, missing) = model.emails(scope: scope)
        guard !emails.isEmpty else {
            copyReport = "No one here has an email address."
            return
        }
        copyReport = Self.write(emails.joined(separator: ", "))
            ? PeopleEmailCopy.report(copied: emails.count, missing: missing)
            : PeopleEmailCopy.failure
    }

    private func copyEmail(of ids: Set<Member.ID>) {
        let person = model.participants.first { ids.contains($0.id) }
        guard let email = person?.member.email else { return }
        if !Self.write(email) {
            copyReport = "Couldn’t copy the email address."
        }
    }

    private static func write(_ text: String) -> Bool {
        #if os(macOS)
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.writeObjects([text as NSString])
        #else
            UIPasteboard.general.string = text
            return true
        #endif
    }
}

/// A change to people that asks first, and its words.
struct PeopleConfirmation {
    enum Kind { case remove, block, reject, cancelInvitation }

    let kind: Kind
    let title: String
    let message: String?
    let button: String
    let keep: String
    let mutations: [ConversationMutation]

    @MainActor
    init(
        kind: Kind, people: [ConversationParticipant], conversation: String,
        details: ConversationDetails, state: ChatSceneState
    ) {
        self.kind = kind
        let ids = people.map(\.id)
        let name = people.count == 1 ? people[0].sortName : nil
        let count = people.count
        keep = kind == .cancelInvitation ? "Keep" : "Cancel"
        switch kind {
        case .remove:
            let single = ConversationMutation.removePerson(ids[0])
            title = name == nil ? "Remove \(count) people from “\(conversation)”?"
                : ConversationDetailsText.confirmationTitle(single, details: details, state: state)
            message = ConversationDetailsText.confirmationMessage(single)
            button = ConversationDetailsText.confirmationButton(single)
            mutations = ids.map { .removePerson($0) }
        case .block:
            // Blocking keeps the person in the conversation; what else it
            // changes is the service's, so it isn't promised here.
            title = name.map { "Block \($0)?" } ?? "Block \(count) people?"
            message = name.map { "\($0) stays in this conversation. You can unblock them at any time." }
                ?? "They stay in this conversation. You can unblock them at any time."
            button = "Block"
            mutations = ids.map { .setPersonBlocked($0, true) }
        case .reject:
            title = name.map { "Decline \($0)’s request to join?" } ?? "Decline \(count) requests to join?"
            message = "They won’t be added."
            button = "Decline"
            mutations = ids.map { .rejectRequest($0) }
        case .cancelInvitation:
            title = name.map { "Cancel the invitation to \($0)?" } ?? "Cancel \(count) invitations?"
            message = nil
            button = count == 1 ? "Cancel Invitation" : "Cancel Invitations"
            mutations = ids.map { .removePerson($0) }
        }
    }

    /// The role a row shows, or nil for one the service didn't name.
    static func roleText(_ participant: ConversationParticipant) -> String? {
        switch participant.role {
        case .owner, .manager, .member: ConversationDetailsText.role(participant.role)
        default: nil
        }
    }

    /// "<name>, <role>", and ", external" for someone outside the organization.
    static func rowLabel(_ participant: ConversationParticipant) -> String {
        var label = participant.sortName
        if PeopleScope.of(participant) == .requests {
            label += ", requested to join"
        } else if let role = roleText(participant) {
            label += ", \(role)"
        }
        if participant.isExternal == true {
            label += ", external"
        }
        if participant.isBlocked == true {
            label += ", blocked"
        }
        return label
    }
}
