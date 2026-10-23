import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// The open panel while a write is on its way, and the panel's notice: a
/// late answer reaches only the panel it was sent from.
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

    @Test func closingOrSwitchingThePanelClearsItsNotice() async throws {
        let browser = try await openBrowser(FakeBackend(), at: space)
        browser.notice = "2 people could not be updated."
        browser.openDetails(space)
        #expect(browser.notice != nil)
        browser.openDetails(.init("dm:1"))
        #expect(browser.notice == nil)
        await browser.detailsTask?.value

        browser.notice = "2 people could not be updated."
        browser.closePanel()
        #expect(browser.notice == nil)
        browser.stop()
    }

    @Test func aCreationNoticeSurvivesOpeningTheNewConversation() async throws {
        let browser = try await openBrowser(FakeBackend(), at: space)
        browser.create(ConversationDraft(
            kind: .groupDirectMessage, members: [other, .init("fixture-nobody")]
        ))
        await browser.writeTask?.value
        #expect(browser.panelTarget != nil)
        #expect(browser.panelTarget != space)
        #expect(browser.notice == "Created, but 1 people could not be added.")
        await browser.detailsTask?.value
        browser.stop()
    }
}
