import ChatKit
import SwiftUI
import Testing
@testable import DesignSystem

@MainActor
struct AccountPickerNavigationTests {
    @Test func arrowsMoveFocusWithoutSelectingOrInventingUnavailableActions() {
        var selected: [String] = []
        let actions = AccountPanelActions(
            select: { selected.append($0) },
            add: {},
            resumeSignIn: { _ in },
            manage: {}
        )
        let navigation = AccountPickerNavigation(state: state, actions: actions)
        #expect(navigation.initial == .account("second"))
        #expect(navigation.move(from: .account("first"), direction: .left) == .account("first"))
        #expect(navigation.move(from: .account("second"), direction: .right) == .pending("pending"))
        #expect(navigation.move(from: .pending("pending"), direction: .right) == .add)
        #expect(navigation.move(from: .add, direction: .right) == .add)
        #expect(navigation.move(from: .account("second"), direction: .down) == .manage)
        #expect(navigation.move(from: .manage, direction: .up) == .account("second"))
        #expect(selected.isEmpty)
        let limited = AccountPickerNavigation(state: state, actions: AccountPanelActions(select: { _ in }))
        #expect(limited.tiles == [.account("first"), .account("second")])
        #expect(limited.move(from: .account("first"), direction: .down) == .account("first"))
    }

    @Test func emptyOrRemovedSelectionHasABoundedFallback() {
        var missing = state; missing.selectedID = "removed"
        #expect(AccountPickerNavigation(state: missing, actions: .init(select: { _ in
        })).initial == .account("first"))
        #expect(AccountPickerNavigation(
            state: .init(accounts: [], selectedID: nil, scene: nil),
            actions: .init(select: { _ in })
        ).initial == nil)
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
