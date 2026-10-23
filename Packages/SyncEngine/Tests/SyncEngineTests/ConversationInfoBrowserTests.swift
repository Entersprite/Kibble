import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import ChatPersistence
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ConversationInfoBrowserTests {
    let space = Conversation.ID("space:1")
    let other = Member.ID("fixture-other")

    @Test func integrationsLoadForTheOpenSpace() async throws {
        let backend = FakeBackend()
        let browser = try await openBrowser(backend, at: space)
        browser.loadIntegrations()
        await browser.infoTasks[.integrations]?.value
        #expect(browser.integrations?.canAddApps == true)
        #expect(browser.integrations?.apps == [])
        #expect(!browser.isLoadingIntegrations)
        #expect(browser.integrationsError == nil)
        browser.stop()
    }

    @Test func aLateIntegrationsAnswerForAnotherConversationIsDropped() async throws {
        let backend = HeldInfoBackend()
        let browser = try await openBrowser(backend, at: space)
        await backend.hold(.integrations)
        browser.loadIntegrations()
        let pending = try #require(browser.infoTasks[.integrations])
        try await waitUntilHeld(backend)
        browser.openDetails(.init("dm:1"))
        await backend.release()
        await pending.value
        await browser.detailsTask?.value
        #expect(browser.integrations == nil)
        #expect(!browser.isLoadingIntegrations)
        browser.stop()
    }

    @Test func aLateWebhookURLAfterClosingIsNeverDelivered() async throws {
        let backend = HeldInfoBackend()
        let browser = try await openBrowser(backend, at: space)
        let webhook = try await saveWebhook(in: browser)
        await backend.hold(.webhookURL)
        var delivered = false
        browser.webhookURL(webhook) { _ in delivered = true }
        let pending = try #require(browser.infoTasks[.webhookURL])
        try await waitUntilHeld(backend)
        browser.closePanel()
        await backend.release()
        await pending.value
        #expect(!delivered)
        browser.stop()
    }

    @Test func webhookURLIsNotRetainedInState() async throws {
        let backend = FakeBackend()
        let browser = try await openBrowser(backend, at: space)
        let webhook = try await saveWebhook(in: browser)
        var delivered: URL?
        browser.webhookURL(webhook) { result in
            if case let .success(url) = result {
                delivered = url
            }
        }
        await browser.infoTasks[.webhookURL]?.value
        let url = try #require(delivered)
        #expect(!Self.retains(url, in: browser))
        browser.stop()
    }

    @Test func confirmedWebhookSaveReloadsIntegrations() async throws {
        let backend = FakeBackend()
        let browser = try await openBrowser(backend, at: space)
        browser.mutate(.saveWebhook(id: nil, name: "CI", avatarURL: ""))
        await browser.writeTask?.value
        await browser.infoTasks[.integrations]?.value
        #expect(browser.integrations?.webhooks.map(\.name) == ["CI"])
        browser.stop()
    }

    @Test func emailGenerationReloadsEmail() async throws {
        let backend = FakeBackend()
        let browser = try await openBrowser(backend, at: space)
        browser.mutate(.generateEmail)
        await browser.writeTask?.value
        await browser.infoTasks[.email]?.value
        #expect(browser.email?.address?.hasSuffix("@example.invalid") == true)
        #expect(browser.emailError == nil)
        browser.stop()
    }

    @Test func pendingMutationShowsUntilTheResultLands() async throws {
        let backend = HeldInfoBackend()
        let browser = try await openBrowser(backend, at: space)
        await backend.hold(.mutation)
        browser.mutate(.setRole(other, .manager))
        #expect(browser.pendingMutation == .setRole(other, .manager))
        try await waitUntilHeld(backend)
        #expect(browser.pendingMutation == .setRole(other, .manager))
        await backend.release()
        await browser.writeTask?.value
        #expect(browser.pendingMutation == nil)
        await browser.detailsTask?.value
        let confirmed = browser.participants.first { $0.id == other }?.role
        #expect(confirmed == .manager)

        await backend.failMutations()
        browser.mutate(.setRole(other, .member))
        #expect(browser.pendingMutation == .setRole(other, .member))
        await browser.writeTask?.value
        #expect(browser.pendingMutation == nil)
        #expect(browser.panelError != nil)
        #expect(browser.participants.first { $0.id == other }?.role == confirmed)
        browser.stop()
    }

    @Test func loadAllParticipantsPagesToTheEnd() async throws {
        let backend = RecordingBackend(world: Self.fivePeople, pageSize: 2)
        let browser = try await openBrowser(backend, at: space)
        #expect(browser.participants.count == 2)
        browser.loadAllParticipants()
        #expect(browser.isLoadingAllParticipants)
        await browser.infoTasks[.allParticipants]?.value
        #expect(browser.participants.count == 5)
        #expect(browser.participantCursor == nil) // AppCore's hasMoreParticipants
        #expect(!browser.isLoadingAllParticipants)
        browser.stop()
    }

    @Test func loadAllParticipantsFailurePartwayKeepsHasMore() async throws {
        let backend = HeldInfoBackend(world: Self.fivePeople, pageSize: 2)
        let browser = try await openBrowser(backend, at: space)
        await backend.failLaterPages()
        browser.loadAllParticipants()
        await browser.infoTasks[.allParticipants]?.value
        #expect(browser.panelError != nil)
        #expect(browser.participantCursor != nil) // AppCore's hasMoreParticipants
        #expect(browser.participants.count == 2)
        #expect(!browser.isLoadingAllParticipants)
        browser.stop()
    }

    @Test func openAppReturnsATypedAppConversation() async throws {
        let backend = FakeBackend()
        let store = try ChatStore.inMemory()
        let browser = try await openBrowser(backend, at: space, store: store)
        browser.searchApps("")
        await browser.infoTasks[.apps]?.value
        let app = try #require(browser.appResults.first).id
        browser.mutate(.addApp(app))
        await browser.writeTask?.value
        var opened: Conversation.ID?
        browser.onOpen = { opened = $0 }
        browser.openApp(app)
        await browser.writeTask?.value
        let id = try #require(opened)
        #expect(try store.conversations().first { $0.id == id }?.kind == .appDirectMessage)
        #expect(browser.panelTarget == nil)
        browser.stop()
    }

    @Test func conversionConsequencesLoadForAGroupChat() async throws {
        let backend = FakeBackend(world: Self.fivePeople)
        try await backend.connect()
        let group = try await backend.createConversation(.init(
            kind: .groupDirectMessage, members: [other, .init("fixture-person-1")]
        )).conversation.id
        let browser = try await openBrowser(backend, at: group)
        browser.loadConversion()
        #expect(browser.isLoadingConversion)
        await browser.infoTasks[.conversion]?.value
        #expect(browser.conversion?.requiresHistoryAcknowledgement == true)
        #expect(browser.conversion?.items.isEmpty == false)
        #expect(browser.conversionError == nil)
        browser.stop()
    }

    @Test func emailAndAppSearchAreDroppedWhenThePanelCloses() async throws {
        let backend = FakeBackend()
        let browser = try await openBrowser(backend, at: space)
        browser.loadEmail()
        browser.searchApps("Poll")
        browser.closePanel()
        await browser.infoTasks[.email]?.value
        await browser.infoTasks[.apps]?.value
        #expect(browser.email == nil)
        #expect(!browser.isLoadingEmail)
        #expect(browser.appResults.isEmpty)
        #expect(!browser.isSearchingApps)
        browser.stop()
    }
}

extension ConversationInfoBrowserTests {
    @Test func pagingAndMutationsExcludeEachOtherAndAReloadMidPagingIsFollowed() async throws {
        let backend = HeldInfoBackend(world: Self.fivePeople, pageSize: 2)
        let browser = try await openBrowser(backend, at: space)
        await backend.hold(.mutation)
        browser.mutate(.setRole(other, .manager))
        browser.loadAllParticipants()
        #expect(browser.infoTasks[.allParticipants] == nil)
        #expect(!browser.isLoadingAllParticipants)
        try await waitUntilHeld(backend)
        await backend.release()
        await browser.writeTask?.value
        await browser.detailsTask?.value

        await backend.hold(.laterPages)
        browser.loadAllParticipants()
        let paging = try #require(browser.infoTasks[.allParticipants])
        try await waitUntilHeld(backend)
        browser.mutate(.setRole(other, .member))
        #expect(browser.pendingMutation == nil)
        // What a confirmed mutation's `applyManagementResult` does to the list.
        browser.openDetails(space)
        await backend.release()
        await paging.value
        let quietlyPartial = !browser.isLoadingAllParticipants && browser.panelError == nil
            && browser.participants.count < 5
        #expect(!quietlyPartial)
        #expect(!browser.isLoadingAllParticipants)
        #expect(browser.participants.count == 5)
        #expect(browser.participantCursor == nil)
        #expect(browser.participants.first { $0.id == other }?.role == .manager)
        browser.stop()
    }

    @Test func anUnrelatedConversationChangeDoesNotFailAnOpenRead() async throws {
        let backend = HeldInfoBackend()
        let browser = try await openBrowser(backend, at: space)
        await backend.hold(.integrations)
        browser.loadIntegrations()
        let pending = try #require(browser.infoTasks[.integrations])
        try await waitUntilHeld(backend)
        await browser.engine.invalidateConversationSnapshot(.init("dm:1"))
        await backend.release()
        await pending.value
        #expect(browser.integrations != nil)
        #expect(browser.integrationsError == nil)
        browser.stop()
    }

    @Test func aPendingMutationShowsOnlyOnItsOwnPanel() async throws {
        let backend = HeldInfoBackend()
        let browser = try await openBrowser(backend, at: space)
        await backend.hold(.mutation)
        browser.mutate(.setRole(other, .manager))
        try await waitUntilHeld(backend)
        browser.openDetails(.init("dm:1"))
        #expect(browser.pendingMutation == nil)
        browser.openDetails(space)
        #expect(browser.pendingMutation == .setRole(other, .manager))
        await backend.release()
        await browser.writeTask?.value
        #expect(browser.pendingMutation == nil)
        browser.stop()
    }

    @Test func anUnconfirmedMutationClearsItsPendingState() async throws {
        let backend = RecordingBackend()
        let browser = try await openBrowser(backend, at: space)
        await backend.leaveMutationsUnconfirmed(true)
        browser.mutate(.setRole(other, .manager))
        #expect(browser.pendingMutation == .setRole(other, .manager))
        await browser.writeTask?.value
        #expect(browser.pendingMutation == nil)
        #expect(browser.panelError != nil)
        browser.stop()
    }

    static let fivePeople: FixtureWorld = {
        var world = FixtureWorld.minimal
        let extra = (1 ... 3).map {
            Member(id: .init("fixture-person-\($0)"), kind: .human, displayName: "Person \($0)")
        }
        world.members += extra
        if let index = world.conversations.firstIndex(where: { $0.id == .init("space:1") }) {
            world.conversations[index].members += extra.map(\.id)
        }
        return world
    }()

    func openBrowser(
        _ backend: some ChatBackend,
        at id: Conversation.ID,
        store: ChatStore? = nil
    ) async throws -> ConversationBrowser {
        try await backend.connect()
        let engine = try SyncEngine(backend: backend, store: store ?? ChatStore.inMemory())
        let browser = ConversationBrowser(engine: engine)
        browser.openDetails(id)
        await browser.detailsTask?.value
        try #require(browser.details?.conversation.id == id)
        return browser
    }

    func saveWebhook(in browser: ConversationBrowser) async throws -> String {
        browser.mutate(.saveWebhook(id: nil, name: "CI", avatarURL: ""))
        await browser.writeTask?.value
        await browser.infoTasks[.integrations]?.value
        return try #require(browser.integrations?.webhooks.first).id
    }

    func waitUntilHeld(_ backend: HeldInfoBackend) async throws {
        for _ in 0 ..< 200 where await !backend.isHolding {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await backend.isHolding)
    }

    /// Walks the browser's stored values a few levels deep for the URL.
    static func retains(_ url: URL, in value: Any, depth: Int = 3) -> Bool {
        if let found = value as? URL, found == url {
            return true
        }
        if let text = value as? String, text.contains(url.absoluteString) {
            return true
        }
        guard depth > 0 else { return false }
        return Mirror(reflecting: value).children.contains { retains(url, in: $0.value, depth: depth - 1) }
    }
}
