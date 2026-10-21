import ChatKit
import SwiftUI
import Testing
@testable import DesignSystem

@MainActor
struct AccountPanelNavigationTests {
    private let status: [AccountStatusRow] = [.automatic, .doNotDisturb, .away, .setStatus]

    @Test func arrowsMoveAcrossBothColumnsWithoutSelectingOrInventingUnavailableActions() {
        var selected: [String] = []
        let actions = AccountPanelActions(
            select: { selected.append($0) },
            add: {},
            resumeSignIn: { _ in },
            manage: {}
        )
        let navigation = AccountPanelNavigation(state: state, actions: actions, status: status)
        #expect(navigation.initial == .account("second"))
        // Nothing highlighted yet: the arrows start from the current account.
        #expect(navigation.move(from: nil, direction: .right) == .pending("pending"))
        #expect(navigation.move(from: .account("second"), direction: .right) == .pending("pending"))
        #expect(navigation.move(from: .pending("pending"), direction: .right) == .add)
        #expect(navigation.move(from: .add, direction: .right) == .add)
        #expect(navigation.move(from: .account("second"), direction: .down) == .manage)
        #expect(navigation.move(from: .account("second"), direction: .up) == .account("second"))
        // Left of the first tile is the status column, and Right comes back.
        #expect(navigation.move(from: .account("first"), direction: .left) == .status(.automatic))
        #expect(navigation.move(from: .status(.automatic), direction: .up) == .status(.automatic))
        #expect(navigation.move(from: .status(.automatic), direction: .down) == .status(.doNotDisturb))
        #expect(navigation.move(from: .status(.setStatus), direction: .down) == .status(.setStatus))
        #expect(navigation.move(from: .status(.away), direction: .right) == .account("second"))
        #expect(navigation.move(from: .manage, direction: .up) == .account("second"))
        #expect(navigation.move(from: .manage, direction: .left) == .status(.automatic))
        #expect(selected.isEmpty)

        let limited = AccountPanelNavigation(
            state: state, actions: AccountPanelActions(select: { _ in }), status: []
        )
        #expect(limited.tiles == [.account("first"), .account("second")])
        #expect(limited.move(from: .account("first"), direction: .down) == .account("first"))
        #expect(limited.move(from: .account("first"), direction: .left) == .account("first"))
    }

    @Test func eachColumnReturnsToWhereItsHighlightLastWas() {
        let actions = AccountPanelActions(select: { _ in }, add: {}, manage: {})
        let navigation = AccountPanelNavigation(state: state, actions: actions, status: status)
        var recent = AccountPanelNavigation.Recent()
        recent.note(.add)
        recent.note(.status(.away))
        recent.note(.manage)
        #expect(navigation.move(from: .manage, direction: .up, recent: recent) == .add)
        #expect(navigation.move(from: .status(.automatic), direction: .right, recent: recent) == .add)
        #expect(navigation.move(from: .account("first"), direction: .left, recent: recent) == .status(.away))
        // A target that has gone falls back rather than sticking.
        recent.note(.status(.clearStatus))
        #expect(navigation.move(from: .manage, direction: .left, recent: recent) == .status(.automatic))
    }

    @Test func tabFollowsReadingOrderAndWrapsBothWays() {
        let actions = AccountPanelActions(select: { _ in }, add: {}, manage: {})
        let navigation = AccountPanelNavigation(state: state, actions: actions, status: [.automatic, .away])
        #expect(navigation.order == [
            .status(.automatic), .status(.away), .account("first"), .account("second"), .add, .manage
        ])
        #expect(navigation.next(after: nil, backward: false) == .status(.automatic))
        #expect(navigation.next(after: nil, backward: true) == .manage)
        #expect(navigation.next(after: .status(.away), backward: false) == .account("first"))
        #expect(navigation.next(after: .manage, backward: false) == .status(.automatic))
        #expect(navigation.next(after: .status(.automatic), backward: true) == .manage)
    }

    @Test func emptyOrRemovedSelectionHasABoundedFallback() {
        var missing = state; missing.selectedID = "removed"
        #expect(AccountPanelNavigation(state: missing, actions: .init(select: { _ in
        }), status: []).initial == .account("first"))
        let empty = AccountPanelNavigation(
            state: .init(accounts: [], selectedID: nil, scene: nil),
            actions: .init(select: { _ in }), status: []
        )
        #expect(empty.initial == nil)
        #expect(empty.move(from: nil, direction: .right) == nil)
        #expect(empty.next(after: nil, backward: false) == nil)
        // A highlight on an account that has since gone starts over.
        let navigation = AccountPanelNavigation(state: state, actions: .init(select: { _ in }), status: [])
        #expect(navigation.move(from: .account("removed"), direction: .left) == .account("second"))
    }

    /// What VoiceOver hears as the highlight moves: the words the panel
    /// draws, and which row is checked and which account is current.
    @Test func theHighlightIsSpokenWithThePanelsOwnWords() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let away = StatusMenuModel(availability: .away, status: nil, now: now)
        func spoken(_ target: AccountPanelTarget) -> String? {
            AccountPanelSpeech.text(for: target, state: state, status: away)
        }
        #expect(spoken(.status(.away)) == "Set as away, selected")
        #expect(spoken(.status(.automatic)) == "Automatic")
        #expect(spoken(.status(.doNotDisturb)) == away.doNotDisturbTitle)
        #expect(spoken(.status(.setStatus)) == "Set a Status…")
        #expect(spoken(.account("second")) == "second, current account")
        #expect(spoken(.account("first")) == "first")
        #expect(spoken(.account("removed")) == nil)
        #expect(spoken(.pending("pending")) == "Finish Signing In")
        #expect(spoken(.add) == "Add Account")
        #expect(spoken(.manage) == "Manage Accounts…")
        // No status section, nothing to say for its rows.
        #expect(AccountPanelSpeech.text(for: .status(.away), state: state, status: nil) == nil)
    }

    @Test func badgesExcludeTheSelectedAccountAndDisabledUnread() {
        var panel = state
        #expect(panel.othersUnread == 3)
        #expect(!panel.othersHaveProblem)
        panel.accounts.append(row("third", unread: 100, enabled: false, problem: .signInRequired))
        #expect(panel.othersUnread == 3)
        #expect(panel.othersHaveProblem)
    }

    private var state: AccountPanelState {
        AccountPanelState(
            accounts: [row("first", unread: 3), row("second", unread: 8)],
            pendingSignIns: [.init(id: "pending")],
            selectedID: "second", scene: nil
        )
    }

    private func row(
        _ id: String,
        unread: Int,
        enabled: Bool = true,
        problem: AccountPanelAccount.Problem? = nil
    ) -> AccountPanelAccount {
        AccountPanelAccount(
            id: id,
            label: id,
            name: nil,
            email: nil,
            managedBy: nil,
            unread: unread,
            problem: problem,
            isEnabled: enabled,
            me: .init(id),
            directory: [:],
            imageLoader: nil
        )
    }
}
