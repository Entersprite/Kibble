import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// Several people's changes from one selection: sent one after another as
/// one submission, stopped at the first refusal, and reloaded once.
extension ConversationInfoBrowserTests {
    private var three: [Member.ID] {
        (1 ... 3).map { Member.ID("fixture-person-\($0)") }
    }

    private func remaining(_ backend: HeldInfoBackend) async throws -> Set<Member.ID> {
        let page = try await backend.inner.participants(in: space, after: nil)
        return Set(page.participants.map(\.id)).intersection(three)
    }

    @Test func removingThreePeopleRemovesAllThreeWithOneReload() async throws {
        let backend = HeldInfoBackend(world: Self.fivePeople)
        let browser = try await openBrowser(backend, at: space)
        let readsBefore = await backend.detailsReads
        browser.mutateEach(three.map { .removePerson($0) })
        #expect(browser.isSubmitting)
        #expect(browser.pendingMutation == .removePerson(three[0]))
        await browser.writeTask?.value
        await browser.detailsTask?.value
        #expect(try await remaining(backend).isEmpty)
        #expect(await backend.detailsReads - readsBefore == 1)
        #expect(!browser.isSubmitting)
        #expect(browser.pendingMutation == nil)
        #expect(browser.panelError == nil)
        #expect(Set(browser.participants.map(\.id)).isDisjoint(with: three))
        browser.stop()
    }

    @Test func aRefusalPartwayStopsTheRestAndSaysHowManyWentThrough() async throws {
        let backend = HeldInfoBackend(world: Self.fivePeople)
        let browser = try await openBrowser(backend, at: space)
        await backend.failMutation(number: 2)
        browser.mutateEach(three.map { .removePerson($0) })
        await browser.writeTask?.value
        await browser.detailsTask?.value
        #expect(try await remaining(backend) == [three[1], three[2]])
        #expect(await backend.mutationCount == 2)
        #expect(browser.panelError == "Removed 1 of 3 people. The change failed.")
        #expect(!browser.isSubmitting)
        browser.stop()
    }

    @Test func aPanelSwitchMidBatchDropsTheRest() async throws {
        let backend = HeldInfoBackend(world: Self.fivePeople)
        let browser = try await openBrowser(backend, at: space)
        await backend.hold(.mutation)
        browser.mutateEach(three.map { .removePerson($0) })
        try await waitUntilHeld(backend)
        switchPanelMidWrite(browser, to: .init("dm:1"))
        await backend.release()
        await browser.writeTask?.value
        await browser.detailsTask?.value
        #expect(await backend.mutationCount == 1)
        #expect(try await remaining(backend) == [three[1], three[2]])
        #expect(browser.panelTarget == .init("dm:1"))
        #expect(!browser.isSubmitting)
        browser.stop()
    }

    @Test func aBatchIsRefusedWhileEveryPageIsLoading() async throws {
        let backend = HeldInfoBackend(world: Self.fivePeople, pageSize: 2)
        let browser = try await openBrowser(backend, at: space)
        await backend.hold(.laterPages)
        browser.loadAllParticipants()
        try await waitUntilHeld(backend)
        browser.mutateEach(three.map { .removePerson($0) })
        #expect(!browser.isSubmitting)
        await backend.release()
        await browser.infoTasks[.allParticipants]?.value
        #expect(await backend.mutationCount == 0)
        browser.stop()
    }
}
