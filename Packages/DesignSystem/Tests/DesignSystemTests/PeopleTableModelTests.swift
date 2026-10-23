import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// The People table's rules: which scopes exist, what search and the footer
/// say, and which actions a selection gets.
struct PeopleTableModelTests {
    private func person(
        _ id: String,
        name: String? = nil,
        email: String? = nil,
        role: ConversationRole = .member,
        state: ParticipantState = .joined,
        actions: Set<String> = [],
        roles: [ConversationRole] = [],
        kind: Member.Kind = .human
    ) -> ConversationParticipant {
        ConversationParticipant(
            member: Member(id: .init(id), kind: kind, displayName: name, email: email),
            role: role, state: state, allowedActions: actions, allowedRoles: roles
        )
    }

    private func members(_ count: Int) -> [ConversationParticipant] {
        (1 ... count).map { person("m\($0)", name: "Member \($0)", email: "m\($0)@example.test") }
    }

    @Test func scopesAppearOnlyWhenTheyHavePeople() {
        let joined = PeopleTableModel(participants: members(2), hasMore: false, memberCount: 2)
        #expect(joined.scopes == [.members])
        let invited = PeopleTableModel(
            participants: members(2) + [person("i", state: .invited)], hasMore: false, memberCount: 2
        )
        #expect(invited.scopes == [.members, .invited])
        let all = PeopleTableModel(
            participants: members(2) + [person("r", state: .requested), person("i", state: .invited)],
            hasMore: false, memberCount: 2
        )
        #expect(all.scopes == [.members, .invited, .requests])
    }

    @Test func searchMatchesNameOrEmailCaseInsensitively() {
        let model = PeopleTableModel(
            participants: [
                person("a", name: "Ana Lee", email: "ana@studio.example"),
                person("b", name: "Sam Ortiz", email: "sam@partner.example"),
                person("c", name: "Kai Rivera", email: "kai@studio.example")
            ],
            hasMore: false, memberCount: 3
        )
        let byName = model.rows(scope: .members, query: "ana", sort: [])
        #expect(byName.map(\.id.rawValue) == ["a"])
        let byEmail = model.rows(scope: .members, query: "STUDIO", sort: [])
        #expect(byEmail.map(\.id.rawValue) == ["a", "c"])
        let reversed = [KeyPathComparator(\ConversationParticipant.sortName, order: .reverse)]
        let sorted = model.rows(scope: .members, query: "", sort: reversed)
        #expect(sorted.map(\.id.rawValue) == ["b", "c", "a"])
    }

    @Test func appsAreNotListedAsPeople() {
        let model = PeopleTableModel(
            participants: members(1) + [person("bot", name: "Calendar", kind: .app)],
            hasMore: false, memberCount: 2
        )
        #expect(model.rows(scope: .members, query: "", sort: []).map(\.id.rawValue) == ["m1"])
    }

    @Test func countTextIsHonestAboutFilteringAndLoadedPages() {
        let all = PeopleTableModel(participants: members(14), hasMore: false, memberCount: 14)
        #expect(all.countText(scope: .members, shown: 14) == "14 members")
        #expect(all.countText(scope: .members, shown: 3) == "Showing 3 of 14")
        let paged = PeopleTableModel(participants: members(50), hasMore: true, memberCount: 120)
        #expect(paged.countText(scope: .members, shown: 3) == "Showing 3 of 50 loaded")
        #expect(paged.countText(scope: .members, shown: 50) == "50 of 120 members loaded")
        let one = PeopleTableModel(participants: members(1), hasMore: false, memberCount: 1)
        #expect(one.countText(scope: .members, shown: 1) == "1 member")
    }

    @Test func selectionCommandsAreTheIntersection() {
        let owner = person(
            "owner", email: "o@example.test", role: .owner,
            actions: ["setRole", "removePerson"], roles: [.member, .manager, .owner]
        )
        let member = person(
            "member", email: "m@example.test",
            actions: ["setRole", "removePerson", "blockPerson"], roles: [.member, .manager, .owner]
        )
        let model = PeopleTableModel(
            participants: [owner, member], hasMore: false, memberCount: 2, canMessage: true
        )
        let both = model.commands(for: [owner.id, member.id])
        #expect(both == [.makeRole(.manager), .remove])
        #expect(!both.contains(.message))
        #expect(!both.contains(.copyEmail))
        let single = model.commands(for: [member.id])
        #expect(single == [
            .message, .makeRole(.manager), .makeRole(.owner), .copyEmail, .block, .remove
        ])
    }

    @Test func messageNeedsAWindowThatCanMessageAndAJoinedPersonOtherThanMe() {
        let other = person("other")
        let me = person("me")
        let invited = person("invited", state: .invited)
        let cannot = PeopleTableModel(participants: [other], hasMore: false, memberCount: 1)
        #expect(!cannot.commands(for: [other.id]).contains(.message))
        let can = PeopleTableModel(
            participants: [other, me, invited], hasMore: false, memberCount: 2,
            canMessage: true, me: me.id
        )
        #expect(can.commands(for: [other.id]).contains(.message))
        #expect(!can.commands(for: [me.id]).contains(.message))
        #expect(!can.commands(for: [invited.id]).contains(.message))
    }

    @Test func invitedPeopleGetCancelInvitationNotRoles() {
        let invited = person(
            "invited", email: "i@example.test", state: .invited,
            actions: ["setRole", "removePerson", "blockPerson"], roles: [.member, .manager]
        )
        let model = PeopleTableModel(participants: [invited], hasMore: false, memberCount: 0)
        #expect(model.commands(for: [invited.id]) == [.cancelInvitation])
    }

    @Test func requestsGetApproveAndReject() {
        let request = person("asks", state: .requested, actions: ["approveRequest", "rejectRequest"])
        let model = PeopleTableModel(participants: [request], hasMore: false, memberCount: 0)
        #expect(model.commands(for: [request.id]) == [.approve, .reject])
        #expect(model.commands(for: []) == [])
    }

    @Test func blockedPeopleGetUnblock() {
        var blocked = person("blocked", actions: ["unblockPerson"])
        blocked.isBlocked = true
        let model = PeopleTableModel(participants: [blocked], hasMore: false, memberCount: 1)
        #expect(model.commands(for: [blocked.id]) == [.unblock])
    }

    @Test func emailsReportPeopleWithoutAddress() {
        let model = PeopleTableModel(
            participants: [
                person("a", email: "a@example.test"),
                person("b"),
                person("c", email: "c@example.test"),
                person("i", email: "i@example.test", state: .invited)
            ],
            hasMore: false, memberCount: 3
        )
        let result = model.emails(scope: .members)
        #expect(result.emails.count == 2)
        #expect(result.missing == 1)
        #expect(model.emails(scope: .invited).emails == ["i@example.test"])
    }

    @Test func copyReportSaysWhatWasCopiedAndWhoHadNoAddress() {
        #expect(PeopleEmailCopy.report(copied: 12, missing: 2)
            == "Copied 12 emails. 2 people have no email address.")
        #expect(PeopleEmailCopy.report(copied: 1, missing: 0) == "Copied 1 email.")
        #expect(PeopleEmailCopy.report(copied: 3, missing: 1)
            == "Copied 3 emails. 1 person has no email address.")
    }

    @Test func copyAfterLoadingFailsWhenPagesAreLeftOrLoadingFailed() {
        var browser = ConversationBrowserScene()
        #expect(PeopleEmailCopy.canCopyLoaded(browser))
        browser.hasMoreParticipants = true
        #expect(!PeopleEmailCopy.canCopyLoaded(browser))
        browser.hasMoreParticipants = false
        browser.panelError = "Not everyone could be loaded. Try again."
        #expect(!PeopleEmailCopy.canCopyLoaded(browser))
    }

    @Test func countTextDoesNotCallAListCompleteAfterAnError() {
        // A repeated page clears the cursor and sets the panel's error.
        let partial = PeopleTableModel(
            participants: members(14), hasMore: false, memberCount: 20, isComplete: false
        )
        #expect(partial.countText(scope: .members, shown: 14) == "14 members loaded")
        #expect(partial.countText(scope: .members, shown: 3) == "Showing 3 of 14 loaded")
    }

    @Test func aRepeatedPageIsNotACompleteList() {
        var browser = ConversationBrowserScene()
        browser.hasMoreParticipants = false
        browser.panelError = "The service repeated a page. Reload to see more people."
        #expect(!PeopleEmailCopy.canCopyLoaded(browser))
        #expect(PeopleEmailCopy.step(started: false, browser: browser) == .awaitStart)
        #expect(PeopleEmailCopy.step(started: true, browser: browser) == .fail)
    }

    @Test func aCopyWaitingOnPagesCopiesOnlyACompleteList() {
        var browser = ConversationBrowserScene()
        browser.hasMoreParticipants = true
        #expect(PeopleEmailCopy.step(started: false, browser: browser) == .awaitStart)
        browser.isLoadingAllParticipants = true
        #expect(PeopleEmailCopy.step(started: false, browser: browser) == .loading)
        // Finished, even before the view saw it start: copy.
        browser.isLoadingAllParticipants = false
        browser.hasMoreParticipants = false
        #expect(PeopleEmailCopy.step(started: false, browser: browser) == .copy)
        #expect(PeopleEmailCopy.step(started: true, browser: browser) == .copy)
        // Stopped with pages left: fail.
        browser.hasMoreParticipants = true
        browser.panelError = "Not everyone could be loaded. Try again."
        #expect(PeopleEmailCopy.step(started: true, browser: browser) == .fail)
    }
}
