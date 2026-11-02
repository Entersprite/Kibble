import ChatKit
import Foundation
import Testing
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ConversationPeopleRefreshTests {
    @Test func confirmedRoleAndRowsRemainVisibleWhilePeopleRefresh() async throws {
        let tests = ConversationInfoBrowserTests()
        let backend = HeldInfoBackend()
        let browser = try await tests.openBrowser(backend, at: tests.space)
        defer { browser.stop() }
        let original = browser.participants.map(\.id)
        try #require(!original.isEmpty)
        #expect(browser.participants.first { $0.id == tests.other }?.role == .member)
        await backend.hold(.participants)
        browser.mutate(.setRole(tests.other, .manager))
        await browser.writeTask?.value
        let refresh = try #require(browser.detailsTask)
        try await waitForPeople(backend)
        #expect(!browser.isSubmitting && browser.isLoadingParticipants)
        #expect(browser.participants.map(\.id) == original)
        #expect(browser.participants.first { $0.id == tests.other }?.role == .manager)
        await backend.release(.participants)
        await refresh.value
        #expect(browser.participants.map(\.id) == original)
        #expect(browser.participants.first { $0.id == tests.other }?.role == .manager)
        #expect(!browser.isLoadingParticipants)
    }

    @Test func reloadingKeepsLoadedRowsThenReplacesTheFirstPage() async throws {
        let tests = ConversationInfoBrowserTests()
        let backend = HeldInfoBackend(world: ConversationInfoBrowserTests.fivePeople, pageSize: 2)
        let browser = try await tests.openBrowser(backend, at: tests.space)
        defer { browser.stop() }
        browser.loadAllParticipants()
        await browser.infoTasks[.allParticipants]?.value
        try #require(browser.participants.count == 5)
        await backend.hold(.participants)
        browser.openDetails(tests.space)
        #expect(browser.participants.count == 5)
        #expect(browser.isLoadingParticipants)
        let refresh = try #require(browser.detailsTask)
        try await waitForPeople(backend)
        await backend.release(.participants)
        await refresh.value
        #expect(browser.participants.count == 2)
        #expect(browser.participantCursor != nil)
    }

    @Test func aPartlyRefusedRoleBatchRetainsOnlyConfirmedChangesDuringRefresh() async throws {
        let tests = ConversationInfoBrowserTests()
        let backend = HeldInfoBackend(world: ConversationInfoBrowserTests.fivePeople)
        let browser = try await tests.openBrowser(backend, at: tests.space)
        defer { browser.stop() }
        let people = (1 ... 3).map { Member.ID("fixture-person-\($0)") }
        await backend.hold(.participants)
        await backend.failMutation(number: 2)
        browser.mutateEach(people.map { .setRole($0, .manager) })
        await browser.writeTask?.value
        let refresh = try #require(browser.detailsTask)
        try await waitForPeople(backend)
        #expect(browser.participants.count == 5)
        #expect(browser.participants.first { $0.id == people[0] }?.role == .manager)
        for person in people.dropFirst() {
            #expect(browser.participants.first { $0.id == person }?.role == .member)
        }
        #expect(browser.panelError == "Changed 1 of 3 people. The change failed.")
        await backend.release(.participants)
        await refresh.value
    }

    @Test func aFailedSettingsPeopleRefreshPreservesTheList() async throws {
        let tests = ConversationInfoBrowserTests()
        let backend = HeldInfoBackend()
        let browser = try await tests.openBrowser(backend, at: tests.space)
        defer { browser.stop() }
        let original = browser.participants
        try #require(!original.isEmpty)
        await backend.hold(.participants)
        browser.mutate(.settings(.init(access: .discoverable)))
        await browser.writeTask?.value
        let refresh = try #require(browser.detailsTask)
        try await waitForPeople(backend)
        #expect(browser.participants == original)
        await backend.failNextParticipants()
        await backend.release(.participants)
        await refresh.value
        #expect(browser.participants == original)
        #expect(browser.panelError != nil && !browser.isLoadingParticipants)
    }

    @Test func switchingConversationsClearsRowsAndRejectsTheOldRefresh() async throws {
        let tests = ConversationInfoBrowserTests()
        let world = ConversationInfoBrowserTests.fivePeople
        let backend = HeldInfoBackend(world: world)
        let browser = try await tests.openBrowser(backend, at: tests.space)
        defer { browser.stop() }
        await backend.hold(.participants)
        browser.openDetails(tests.space)
        let old = try #require(browser.detailsTask)
        try await waitForPeople(backend)
        browser.openDetails(.init("dm:1"))
        #expect(browser.participants.isEmpty)
        await backend.release(.participants)
        await old.value
        await browser.detailsTask?.value
        #expect(browser.details?.conversation.id == .init("dm:1"))
        let expected = try #require(world.conversations.first { $0.id == .init("dm:1") }).members
        #expect(Set(browser.participants.map(\.id)) == Set(expected))
    }

    private func waitForPeople(_ backend: HeldInfoBackend) async throws {
        for _ in 0 ..< 200 where await !backend.isHolding(.participants) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await backend.isHolding(.participants))
    }
}
