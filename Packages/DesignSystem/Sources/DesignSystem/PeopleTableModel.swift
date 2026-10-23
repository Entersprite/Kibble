import ChatKit
import Foundation

/// Which people the People table lists: members, open invitations or
/// requests to join.
enum PeopleScope: Hashable {
    case members, invited, requests

    /// The scope a participant is listed in. A state this build doesn't
    /// know lists with the members, never nowhere.
    static func of(_ participant: ConversationParticipant) -> Self {
        switch participant.state {
        case .invited: .invited
        case .requested: .requests
        default: .members
        }
    }

    fileprivate func count(_ count: Int) -> String {
        switch self {
        case .members: count == 1 ? "1 member" : "\(count) members"
        case .invited: "\(count) invited"
        case .requests: count == 1 ? "1 request" : "\(count) requests"
        }
    }
}

/// What the People table offers for a selection.
enum PersonCommand: Hashable {
    case message, makeRole(ConversationRole), copyEmail, block, unblock
    case remove, cancelInvitation, approve, reject
}

/// The People table's rules, apart from its layout. Search, sort and scope
/// work on the pages loaded so far: the participant read has no server-side
/// query, so the footer says when not every page is loaded.
struct PeopleTableModel {
    let participants: [ConversationParticipant]
    let hasMore: Bool
    let memberCount: Int?
    /// False when loading stopped with an error, such as a repeated page:
    /// the loaded list may be partial even with no page left to ask for.
    var isComplete = true
    /// Whether the window can open a direct message (`canOpenDirectConversations`).
    var canMessage = false
    var me: Member.ID?

    init(
        participants: [ConversationParticipant],
        hasMore: Bool,
        memberCount: Int?,
        isComplete: Bool = true,
        canMessage: Bool = false,
        me: Member.ID? = nil
    ) {
        self.isComplete = isComplete
        // Apps are not people; they live in Integrations.
        self.participants = participants.filter { $0.member.kind != .app }
        self.hasMore = hasMore
        self.memberCount = memberCount
        self.canMessage = canMessage
        self.me = me
    }

    /// Members always, then Invited and Requests while anyone is in them.
    var scopes: [PeopleScope] {
        let present = Set(participants.map(PeopleScope.of))
        return [.members] + [PeopleScope.invited, .requests].filter(present.contains)
    }

    func rows(
        scope: PeopleScope,
        query: String,
        sort: [KeyPathComparator<ConversationParticipant>]
    ) -> [ConversationParticipant] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let rows = loaded(scope).filter { participant in
            query.isEmpty || participant.sortName.localizedCaseInsensitiveContains(query)
                || (participant.member.email ?? "").localizedCaseInsensitiveContains(query)
        }
        return sort.isEmpty ? rows : rows.sorted(using: sort)
    }

    /// The footer: everyone, or how many of how many when filtered, and
    /// never a total that only counts the loaded pages as if it were all.
    func countText(scope: PeopleScope, shown: Int) -> String {
        let loaded = loaded(scope).count
        guard hasMore || !isComplete else {
            return shown == loaded ? scope.count(loaded) : "Showing \(shown) of \(loaded)"
        }
        if shown < loaded {
            return "Showing \(shown) of \(loaded) loaded"
        }
        if hasMore, scope == .members, let memberCount, memberCount > loaded {
            return "\(loaded) of \(memberCount) members loaded"
        }
        return "\(scope.count(loaded)) loaded"
    }

    /// The actions every selected person allows, in menu order. Message and
    /// Copy Email are for one person at a time.
    func commands(for selection: Set<Member.ID>) -> [PersonCommand] {
        let selected = participants.filter { selection.contains($0.id) }
        guard let first = selected.first else { return [] }
        let single = selected.count == 1
        var common = commands(of: first, single: single)
        for participant in selected.dropFirst() {
            let allowed = Set(commands(of: participant, single: single))
            common = common.filter(allowed.contains)
        }
        return common
    }

    /// The scope's addresses, and how many people in it have none.
    func emails(scope: PeopleScope) -> (emails: [String], missing: Int) {
        var emails: [String] = []
        var missing = 0
        for participant in loaded(scope) {
            if let email = participant.member.email, !email.isEmpty {
                emails.append(email)
            } else {
                missing += 1
            }
        }
        return (emails, missing)
    }

    private func loaded(_ scope: PeopleScope) -> [ConversationParticipant] {
        participants.filter { PeopleScope.of($0) == scope }
    }

    /// One row's commands, from what the server allows that person, never
    /// from the role label.
    private func commands(of participant: ConversationParticipant, single: Bool) -> [PersonCommand] {
        let scope = PeopleScope.of(participant)
        if scope == .invited {
            // An invitation offers only its cancellation.
            return participant.allowedActions.contains("removePerson") ? [.cancelInvitation] : []
        }
        var commands: [PersonCommand] = []
        if single, canMessage, participant.state == .joined, participant.member.kind == .human,
           participant.id != me {
            commands.append(.message)
        }
        if scope == .members, participant.allowedActions.contains("setRole") {
            commands += participant.allowedRoles.filter { $0 != participant.role }.map(PersonCommand.makeRole)
        }
        if single, let email = participant.member.email, !email.isEmpty {
            commands.append(.copyEmail)
        }
        let granted: [(String, PersonCommand)] = [
            ("blockPerson", .block), ("unblockPerson", .unblock),
            ("approveRequest", .approve), ("rejectRequest", .reject)
        ]
        commands += granted.filter { participant.allowedActions.contains($0.0) }.map(\.1)
        if participant.allowedActions.contains("removePerson") {
            if scope == .members {
                commands.append(.remove)
            }
        }
        return commands
    }
}

/// The table's sort keys: Name, Email and Role.
extension ConversationParticipant {
    var sortName: String {
        PersonName.of(member)
    }

    var sortEmail: String {
        member.email ?? ""
    }

    /// Owners first, then managers, then members.
    var roleRank: Int {
        switch role {
        case .owner: 0
        case .manager: 1
        case .member: 2
        default: 3
        }
    }
}

/// Copy Member Emails' rules: copy only a complete list, and say what happened.
enum PeopleEmailCopy {
    static let failure = "Couldn’t copy member emails."

    /// Whether the list can be copied as complete once loading has ended:
    /// no page left and no failed page.
    static func canCopyLoaded(_ browser: ConversationBrowserScene) -> Bool {
        !browser.hasMoreParticipants && browser.panelError == nil
    }

    /// What a copy waiting on every page does now.
    enum Step: Equatable {
        /// Pages are loading: note that loading started, and keep waiting.
        case loading
        /// The list is complete: copy it.
        case copy
        /// Loading ended without a complete list: copy nothing and say so.
        case fail
        /// Loading hasn't started yet: give it a moment, then fail.
        case awaitStart
    }

    static func step(started: Bool, browser: ConversationBrowserScene) -> Step {
        if browser.isLoadingAllParticipants {
            return .loading
        }
        if canCopyLoaded(browser) {
            return .copy
        }
        return started ? .fail : .awaitStart
    }

    static func report(copied: Int, missing: Int) -> String {
        var report = copied == 1 ? "Copied 1 email." : "Copied \(copied) emails."
        if missing == 1 {
            report += " 1 person has no email address."
        } else if missing > 1 {
            report += " \(missing) people have no email address."
        }
        return report
    }
}

/// What the People section shows above its rows. People already shown stay
/// shown: a failed later page is the header's error, not a reason to hide them.
enum PeopleListStatus: Equatable {
    case loading, failed(String), ready

    static func of(_ browser: ConversationBrowserScene) -> Self {
        if browser.isLoadingParticipants {
            return .loading
        }
        if browser.participants.isEmpty, let error = browser.panelError {
            return .failed(error)
        }
        return .ready
    }

    /// Whether Load More and Load All are offered: there is more, and no
    /// page, all pages or write is on its way.
    static func canLoadMore(_ browser: ConversationBrowserScene) -> Bool {
        browser.hasMoreParticipants && !browser.isLoadingParticipants
            && !browser.isLoadingAllParticipants && !browser.isSubmitting
    }
}
