import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// The open panel while a write is on its way: a late answer reaches only
/// the panel it was sent from.
extension ConversationInfoBrowserTests {
    /// `openDetails` refuses another conversation while a write is on its
    /// way. This stands in for a route that might not, so each write's own
    /// panel fence stays tested.
    func switchPanelMidWrite(_ browser: ConversationBrowser, to id: Conversation.ID) {
        browser.isSubmitting = false
        browser.openDetails(id)
        browser.isSubmitting = true
    }

    @Test func anotherConversationIsRefusedWhileAWriteIsOnItsWay() async throws {
        let backend = HeldInfoBackend()
        let browser = try await openBrowser(backend, at: space)
        await backend.hold(.mutation)
        browser.mutate(.setRole(other, .manager))
        try await waitUntilHeld(backend)
        browser.openDetails(.init("dm:1"))
        #expect(browser.panelTarget == space)
        #expect(browser.details?.conversation.id == space)
        #expect(browser.pendingMutation == .setRole(other, .manager))
        // The same conversation still reloads.
        browser.openDetails(space)
        #expect(browser.panelTarget == space)
        await backend.release()
        await browser.writeTask?.value
        await browser.detailsTask?.value
        #expect(!browser.isSubmitting)
        browser.stop()
    }

    @Test func aLateFailureLeavesTheNextPanelAlone() async throws {
        let backend = HeldInfoBackend()
        let browser = try await openBrowser(backend, at: space)
        await backend.hold(.mutation)
        await backend.failMutations()
        browser.mutate(.setRole(other, .manager))
        try await waitUntilHeld(backend)
        switchPanelMidWrite(browser, to: .init("dm:1"))
        await browser.detailsTask?.value
        #expect(!browser.needsReconciliation)
        await backend.release()
        await browser.writeTask?.value
        #expect(browser.panelTarget == .init("dm:1"))
        #expect(browser.panelError == nil)
        #expect(!browser.needsReconciliation)
        #expect(!browser.isSubmitting)
        browser.stop()
    }

    @Test func aBatchThatFailsFirstAfterASwitchLeavesTheNextPanelAlone() async throws {
        let backend = HeldInfoBackend(world: Self.fivePeople)
        let browser = try await openBrowser(backend, at: space)
        await backend.hold(.mutation)
        await backend.failMutations()
        let people = (1 ... 2).map { Member.ID("fixture-person-\($0)") }
        browser.mutateEach(people.map { .removePerson($0) })
        try await waitUntilHeld(backend)
        switchPanelMidWrite(browser, to: .init("dm:1"))
        await browser.detailsTask?.value
        await backend.release()
        await browser.writeTask?.value
        #expect(await backend.mutationCount == 1)
        #expect(browser.panelError == nil)
        #expect(!browser.needsReconciliation)
        #expect(!browser.isSubmitting)
        browser.stop()
    }
}
