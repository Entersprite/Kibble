import ChatKit
import Testing
@testable import FixtureBackend

struct ConversationIntegrationsTests {
    @Test func integrationsUseTheSharedContractAndRemainConversationScoped() async throws {
        let backend = FakeBackend()
        try await backend.connect()
        let contract: any ChatBackend = backend
        let room = try await contract.createConversation(.init(kind: .space, name: "Builds")).conversation.id
        let other = try await contract.createConversation(.init(kind: .space, name: "Other")).conversation.id
        let mutation = ConversationMutation.saveWebhook(id: nil, name: "Builds", avatarURL: "")
        let result = try await contract.mutateConversation(
            mutation,
            in: room,
            operationID: "create",
            expectedRevision: nil
        )
        #expect(try await contract.mutateConversation(
            mutation,
            in: room,
            operationID: "create",
            expectedRevision: nil
        ) == result)
        let listing = try await contract.conversationIntegrations(room)
        #expect(listing.webhooks.count == 1)
        let hook = try #require(listing.webhooks.first)
        #expect(try await contract.webhookDeliveryURL(hook.id, in: room).host == "example.invalid")
        await #expect(throws: ChatError.self) {
            _ = try await contract.webhookDeliveryURL(hook.id, in: other)
        }
        await #expect(throws: ChatError.self) {
            _ = try await contract.mutateConversation(
                .deleteWebhook(hook.id),
                in: other,
                operationID: "foreign",
                expectedRevision: nil
            )
        }
        await backend.disconnect()
    }

    @Test func appsAreScopedAndOpenTypedAppConversations() async throws {
        let backend = FakeBackend()
        try await backend.connect()
        let contract: any ChatBackend = backend
        let room = try await contract.createConversation(.init(kind: .space, name: "Builds")).conversation.id
        let other = try await contract.createConversation(.init(kind: .space, name: "Other")).conversation.id
        let app = try #require(try await contract.searchConversationApps("", in: room).first)
        _ = try await contract.mutateConversation(
            .addApp(app.id),
            in: room,
            operationID: "app",
            expectedRevision: nil
        )
        #expect(try await contract.searchConversationApps("", in: room).contains { $0.id == app.id } == false)
        #expect(try await contract.openAppConversation(app.id, from: room).kind == .appDirectMessage)
        await #expect(throws: ChatError.self) {
            _ = try await contract.openAppConversation(app.id, from: other)
        }
        _ = try await contract.mutateConversation(
            .removeApp(app.id),
            in: room,
            operationID: "remove",
            expectedRevision: nil
        )
        #expect(try await contract.conversationIntegrations(room).apps.isEmpty)
        await backend.disconnect()
    }

    @Test func settingsKeepUneditedFieldsAndExplicitFalseValues() async throws {
        let backend = FakeBackend()
        try await backend.connect()
        let contract: any ChatBackend = backend
        let room = try await contract.createConversation(.init(
            kind: .space,
            name: "Planning",
            description: "Keep this"
        )).conversation.id
        _ = try await contract.mutateConversation(
            .guidelines("Be kind"),
            in: room,
            operationID: "rules",
            expectedRevision: nil
        )
        let result = try await contract.mutateConversation(
            .settings(.init(requestToJoin: false, permissions: ["manageMembers": .managers])),
            in: room, operationID: "policy", expectedRevision: nil
        )
        #expect(result.details?.settings?.permissions.first { $0.id == "manageMembers" }?
            .audience == .managers)
        #expect(result.details?.settings?.requestToJoin == false)
        #expect(result.details?.description == "Keep this" && result.details?.guidelines == "Be kind")
        await backend.disconnect()
    }

    @Test func emailAndConversionPreserveIdentityAndRequireExplicitAcknowledgement() async throws {
        let backend = FakeBackend(world: .acme)
        try await backend.connect()
        let contract: any ChatBackend = backend
        let room = try await contract.createConversation(.init(kind: .space, name: "Mail")).conversation.id
        #expect(try await contract.conversationEmail(room).canGenerate)
        _ = try await contract.mutateConversation(
            .generateEmail,
            in: room,
            operationID: "email",
            expectedRevision: nil
        )
        let address = try await contract.conversationEmail(room).address
        #expect(address != nil)
        _ = try await contract.mutateConversation(
            .setEmailDelivery(false),
            in: room,
            operationID: "pause",
            expectedRevision: nil
        )
        #expect(try await contract.conversationEmail(room).deliveryEnabled == false)
        _ = try await contract.mutateConversation(
            .deleteEmail,
            in: room,
            operationID: "delete",
            expectedRevision: nil
        )
        #expect(try await contract.conversationEmail(room).address == nil)
        let people = FixtureWorld.acme.members.filter { $0.id != FixtureWorld.acme.me }.prefix(2).map(\.id)
        let chat = try await contract.createConversation(.init(kind: .groupDirectMessage, members: people))
            .conversation
        await #expect(throws: ChatError.self) {
            _ = try await contract.mutateConversation(
                .convertToSpace(name: "Project", emoji: "🐾", acknowledgingHistoryChange: false),
                in: chat.id, operationID: "refused", expectedRevision: nil
            )
        }
        let converted = try await contract.mutateConversation(
            .convertToSpace(name: "Project", emoji: "🐾", acknowledgingHistoryChange: true),
            in: chat.id, operationID: "convert", expectedRevision: nil
        )
        #expect(converted.details?.conversation.id == chat.id)
        #expect(converted.details?.conversation.kind == .space)
        #expect(converted.details?.conversation.members == chat.members)
        #expect(converted.details?.settings?.emoji == "🐾")
        await backend.disconnect()
    }

    @Test func consequencesFollowFixtureConversion() async throws {
        let backend = FakeBackend()
        try await backend.connect()
        let contract: any ChatBackend = backend
        let people = FixtureWorld.acme.members.filter { $0.id != FixtureWorld.acme.me }.prefix(2).map(\.id)
        let chat = try await contract.createConversation(.init(kind: .groupDirectMessage, members: people))
            .conversation
        let result = try await contract.conversionConsequences(chat.id)
        let outcomes: [(ConversionTopic, ConversionOutcome)] = [
            (.sameConversation, .kept), (.membership, .kept), (.messages, .kept), (.undo, .notReversible),
            (.history, .unknown), (.invitations, .unknown), (.integrations, .unknown),
            (.externalPeople, .unknown)
        ]
        #expect(Set(result.items) == Set(outcomes.map { ConversionConsequence(topic: $0.0, outcome: $0.1) }))
        #expect(result.items.count == outcomes.count && result.requiresHistoryAcknowledgement)
        let space = try await contract.createConversation(.init(kind: .space, name: "Builds")).conversation.id
        await #expect(throws: ChatError.self) { _ = try await contract.conversionConsequences(space) }
        await backend.disconnect()
    }

    @Test func defaultOffCapabilitiesRefuseIntegrationsAndPartialFlagsExposeOnlySupportedSections(
    ) async throws {
        var flags = Capabilities.fixture
        flags.extendedFlags.subtract(["conversationApps", "conversationWebhooks", "conversationEmail"])
        let backend = FakeBackend(capabilities: flags)
        try await backend.connect()
        let room = try await backend.createConversation(.init(kind: .space, name: "Room")).conversation.id
        for (index, mutation) in [
            ConversationMutation.addApp(.init("fixture-app-0")),
            .generateEmail,
            .saveWebhook(id: nil, name: "Builds", avatarURL: "")
        ].enumerated() {
            await #expect(throws: ChatError.self) {
                _ = try await backend.mutateConversation(
                    mutation, in: room, operationID: "denied-\(index)", expectedRevision: nil
                )
            }
        }
        await #expect(throws: ChatError.self) { _ = try await backend.conversationIntegrations(room) }
        await backend.disconnect()
        flags.extendedFlags.insert("conversationApps")
        let appsOnly = FakeBackend(capabilities: flags)
        try await appsOnly.connect()
        let other = try await appsOnly.createConversation(.init(kind: .space, name: "Apps")).conversation.id
        let listing = try await appsOnly.conversationIntegrations(other)
        #expect(listing.canAddApps && !listing.canCreateWebhook && listing.webhooks.isEmpty)
        await appsOnly.disconnect()
    }

    @Test func demotionWithdrawsOwnerActionsAndCannotPromoteOrRemoveAnOwner() async throws {
        let world = FixtureWorld.acme
        let backend = FakeBackend(world: world)
        try await backend.connect()
        let peer = try #require(world.members.first { $0.id != world.me && $0.kind == .human }?.id)
        let room = try await backend.createConversation(.init(kind: .space, name: "Roles", members: [peer]))
            .conversation.id
        _ = try await backend.mutateConversation(
            .setRole(peer, .owner),
            in: room,
            operationID: "promote",
            expectedRevision: nil
        )
        _ = try await backend.mutateConversation(
            .setRole(world.me, .manager),
            in: room,
            operationID: "demote",
            expectedRevision: nil
        )
        let owner = try #require(try await backend.participants(in: room, after: nil).participants
            .first { $0.id == peer })
        #expect(owner.allowedRoles.isEmpty && !owner.allowedActions.contains("removePerson"))
        #expect(!owner.allowedActions.contains("setRole"))
        for (index, mutation) in [ConversationMutation.setRole(peer, .member), .removePerson(peer)]
            .enumerated() {
            await #expect(throws: ChatError.self) {
                _ = try await backend.mutateConversation(
                    mutation,
                    in: room,
                    operationID: "denied-\(index)",
                    expectedRevision: nil
                )
            }
        }
        #expect(try await backend.conversationDetails(room).allowedActions.contains("deleteEmail") == false)
        await backend.disconnect()
    }
}
