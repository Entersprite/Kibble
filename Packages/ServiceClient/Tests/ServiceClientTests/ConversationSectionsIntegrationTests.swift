import ChatAPI
import ChatKit
import SyncEngine
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ConversationSectionsIntegrationTests {
    @MainActor
    @Test func connectedSessionProjectsTheSectionsOfItsOwnAccount() async throws {
        let harness = try await ClientHarness.make(seedConversationSections: true)
        let first = try model(harness, account: harness.first)
        let second = try model(harness, account: harness.second)
        try await first.start()
        try await second.start()
        let expectedID = Conversation.ID("same")
        try await eventually { @Sendable in
            await MainActor.run {
                first.conversationSections.first?.name == "First"
                    && second.conversationSections.first?.name == "Second"
            }
        }
        #expect(first.conversationSections.first?.conversationIDs == [expectedID])
        #expect(second.conversationSections.first?.conversationIDs == [expectedID])
        await first.stop()
        #expect(first.conversationSections.isEmpty)
        #expect(second.conversationSections.first?.name == "Second")
        await second.stop()
        await harness.service.shutdown()
    }

    @MainActor
    private func model(_ harness: ClientHarness, account: AccountSummary) throws -> ChatSessionModel {
        let store = try ChatStore.inMemory()
        return ChatSessionModel(
            store: store,
            engine: SyncEngine(backend: harness.backend(account), store: store)
        )
    }

    @MainActor
    @Test func remoteChangesRefreshOnlyTheOwningConnectedSidebar() async throws {
        let harness = try await ClientHarness.make(seedConversationSections: true)
        let first = try model(harness, account: harness.first)
        let second = try model(harness, account: harness.second)
        try await first.start()
        try await second.start()
        try await eventually { @Sendable in
            await MainActor
                .run { !first.conversationSections.isEmpty && !second.conversationSections.isEmpty }
        }

        let moved = ConversationSection(id: "section", name: "Renamed", conversationIDs: [])
        try await harness.providers.changeConversationSections([moved], account: harness.first.id)
        try await eventually { @Sendable in await first.conversationSections == [moved] }
        #expect(second.conversationSections.first?.name == "Second")

        try await harness.providers.changeConversationSections(
            nil, account: harness.first.id, removedSectionID: moved.id
        )
        try await eventually { @Sendable in await first.conversationSections.isEmpty }
        #expect(second.conversationSections.first?.conversationIDs == [.init("same")])

        await first.stop()
        await second.stop()
        await harness.service.shutdown()
    }

    @MainActor
    @Test func editingASectionPreservesMembershipAndTheSameIDInAnotherAccount() async throws {
        let harness = try await ClientHarness.make(seedConversationSections: true)
        let first = try model(harness, account: harness.first)
        let second = try model(harness, account: harness.second)
        try await first.start()
        try await second.start()
        try await eventually { @Sendable in
            await MainActor
                .run { first.conversationSections.count == 1 && second.conversationSections.count == 1 }
        }

        let edit = ConversationSectionEdit(id: "section", name: "Renamed", sort: .name, unreadOnly: true)
        try await first.updateConversationSection(edit)
        let expected = ConversationSection(
            id: "section", name: "Renamed", conversationIDs: [.init("same")], sort: .name, unreadOnly: true
        )
        #expect(first.conversationSections == [expected])
        #expect(try await harness.backend(harness.first).conversationSections() == [expected])
        #expect(try await harness.backend(harness.second).conversationSections() == second
            .conversationSections)
        #expect(second.conversationSections.first?.name == "Second")

        await first.stop()
        await second.stop()
        await harness.service.shutdown()
    }

    @MainActor
    @Test func creationAndDeletionUpdateOnlyTheOwningSidebarAndKeepItsConversations() async throws {
        let harness = try await ClientHarness.make(seedConversationSections: true)
        let first = try model(harness, account: harness.first)
        let second = try model(harness, account: harness.second)
        try await first.start()
        try await second.start()
        try await eventually { @Sendable in
            await MainActor
                .run { first.conversationSections.count == 1 && second.conversationSections.count == 1 }
        }
        try await first.createConversationSection(named: "First")
        #expect(first.conversationSections.map(\.name) == ["First", "First"])
        let created = try #require(first.conversationSections.last)
        #expect(created.id != "section" && created.conversationIDs.isEmpty)
        try await first.deleteConversationSection("section")
        #expect(first.conversationSections == [created])
        #expect(try await harness.backend(harness.first).conversationSections() == [created])
        #expect(first.conversations.contains { $0.id == .init("same") })
        #expect(second.conversationSections.first?.id == "section")
        #expect(second.conversationSections.first?.conversationIDs == [.init("same")])
        await first.stop()
        await second.stop()
        await harness.service.shutdown()
    }

    @MainActor
    @Test func movingAConversationChangesOnlyItsPlacementInTheBoundAccount() async throws {
        let harness = try await ClientHarness.make(seedConversationSections: true)
        let first = try model(harness, account: harness.first)
        let second = try model(harness, account: harness.second)
        try await first.start()
        try await second.start()
        try await eventually { @Sendable in
            await MainActor.run {
                first.conversationSections.count == 1 && second.conversationSections.count == 1
                    && !first.conversations.isEmpty
            }
        }
        let id = Conversation.ID("same")
        try await first.createConversationSection(named: "Work")
        let destination = try #require(first.conversationSections.last)
        try await first.moveConversationToSection(.init(conversationID: id, sectionID: destination.id))
        #expect(first.conversationSections.map(\.conversationIDs) == [[], [id]])
        let persisted = try await harness.backend(harness.first).conversationSections()
        #expect(persisted == first.conversationSections)
        try await first.moveConversationToSection(.init(conversationID: id, sectionID: nil))
        #expect(first.conversationSections.map(\.conversationIDs) == [[], []])
        #expect(first.conversations.contains { $0.id == id })
        #expect(second.conversationSections.first?.conversationIDs == [id])
        await first.stop()
        await second.stop()
        await harness.service.shutdown()
    }
}
