import ChatKit
import Foundation
import Testing
@testable import DesignSystem

/// What your avatar's menu in the sidebar footer holds: your status where the
/// backend can set it, and Sign Out… where the host offers it.
@MainActor
struct AccountMenuTests {
    private let canSetStatus = ChatSceneState(capabilities: Capabilities(canSetStatus: true))

    private func actions(status: Bool = true, signOut: Bool = true) -> ChatSceneActions {
        ChatSceneActions(
            signOut: signOut ? {} : nil,
            setStatus: status ? { _ in } : nil,
            setAvailability: status ? { _ in } : nil
        )
    }

    @Test func statusThenSignOutWhenBothAreOffered() {
        #expect(AccountMenu.sections(state: canSetStatus, actions: actions()) == [.status, .signOut])
    }

    @Test func signOutAloneWhereTheBackendCannotSetStatus() {
        #expect(AccountMenu.sections(state: ChatSceneState(), actions: actions()) == [.signOut])
    }

    @Test func signOutAloneWithoutTheHostsStatusActions() {
        #expect(AccountMenu.sections(state: canSetStatus, actions: actions(status: false)) == [.signOut])
    }

    @Test func statusAloneWithoutSignOut() {
        #expect(AccountMenu.sections(state: canSetStatus, actions: actions(signOut: false)) == [.status])
    }

    @Test func noMenuWhenNeitherIsOffered() {
        let none = actions(status: false, signOut: false)
        #expect(AccountMenu.sections(state: canSetStatus, actions: none).isEmpty)
    }
}
