import ChatKit
import Testing
@testable import FixtureBackend

struct ConversationManagementTests {
    @Test func previewIsDeterministicAndDoesNotJoinAndAnInvitationCanBeBlocked() async throws {
        let backend = FakeBackend()
        try await backend.connect()
        let contract: any ChatBackend = backend
        let before = try await contract.loadConversations()
        let invitations = try await contract.browseSpaces(.init(scope: .invitations), after: nil)
        let invited = try #require(invitations.spaces.first)
        let preview = try await contract.conversationPreview(invited.conversation.id)
        #expect(!preview.messages.isEmpty)
        #expect(try await contract.conversationPreview(invited.conversation.id) == preview)
        #expect(try await contract.loadConversations() == before)
        #expect(invited.allowedActions.contains("block"))
        let result = try await contract.mutateConversation(
            .block, in: invited.conversation.id, operationID: "block-invitation", expectedRevision: nil
        )
        #expect(result.isConfirmed)
        #expect(result.details?.allowedActions.isEmpty == true)
        let after = try await contract.browseSpaces(.init(scope: .invitations), after: nil)
        #expect(!after.spaces.contains { $0.conversation.id == invited.conversation.id })
        #expect(try await contract.loadConversations() == before)
        await backend.disconnect()
    }

    @Test func membershipAndOrganizationFiltersAreIndependentAndSpamIsSeparate() async throws {
        let backend = FakeBackend()
        try await backend.connect()
        let internalSpaces = try await backend.browseSpaces(.init(organization: .internalOnly), after: nil)
        let externalSpaces = try await backend.browseSpaces(.init(organization: .externalOnly), after: nil)
        let all = try await backend.browseSpaces(.init(scope: .all), after: nil)
        let joined = try await backend.browseSpaces(.init(scope: .joined), after: nil)
        let spam = try await backend.browseSpaces(.init(scope: .spamInvitations), after: nil)
        #expect(!internalSpaces.spaces.isEmpty && !externalSpaces.spaces.isEmpty)
        let internalIDs = Set(internalSpaces.spaces.map(\.conversation.id))
        #expect(externalSpaces.spaces.allSatisfy { !internalIDs.contains($0.conversation.id) })
        #expect(joined.spaces.allSatisfy { $0.membership == .joined })
        #expect(all.spaces.contains { $0.membership == .joined })
        #expect(all.spaces.contains { $0.membership != .joined })
        #expect(!spam.spaces.isEmpty)
        #expect(spam.spaces.allSatisfy { row in
            !all.spaces.contains { $0.conversation.id == row.conversation.id }
        })
        await backend.disconnect()
    }

    @Test func partialCreationReturnsTheCreatedSpaceWithoutAnInventedMember() async throws {
        let backend = FakeBackend()
        try await backend.connect()
        let result = try await backend.createConversation(.init(
            kind: .space, name: "Planning", members: [.init("missing-person")]
        ))
        #expect(result.failedMembers == [.init("missing-person")])
        let details = try await backend.conversationDetails(result.conversation.id)
        #expect(details.membership == .joined)
        #expect(details.conversation.members.count == 1)
        let conversations = try await backend.loadConversations()
        #expect(conversations.contains { $0.id == result.conversation.id })
    }

    @Test func browsingDoesNotJoinAndJoiningIsConfirmed() async throws {
        let backend = FakeBackend()
        try await backend.connect()
        let before = try await backend.loadConversations()
        let page = try await backend.browseSpaces(.init(scope: .discover), after: nil)
        let found = try #require(page.spaces.first)
        #expect(found.membership != .joined)
        let unchanged = try await backend.loadConversations()
        #expect(unchanged == before)
        let result = try await backend.mutateConversation(
            .join,
            in: found.conversation.id,
            operationID: "join-one",
            expectedRevision: nil
        )
        #expect(result.details?.membership == .joined)
        let after = try await backend.loadConversations()
        #expect(after.count == before.count + 1)
        let replay = try await backend.mutateConversation(
            .join,
            in: found.conversation.id,
            operationID: "join-one",
            expectedRevision: nil
        )
        #expect(replay == result)
        await #expect(throws: ChatError.self) {
            _ = try await backend.mutateConversation(
                .requestJoin,
                in: found.conversation.id,
                operationID: "join-one",
                expectedRevision: nil
            )
        }
    }

    @Test func directoryCursorsAreQueryBound() async throws {
        let backend = FakeBackend(pageSize: 1)
        try await backend.connect()
        await #expect(throws: ChatError.self) {
            _ = try await backend.browseSpaces(
                .init(scope: .discover, text: "Coffee"),
                after: "spaces:discover:other|1"
            )
        }
    }
}

extension ConversationManagementTests {
    @Test func joiningDoesNotGrantOwnershipAndKeepsTheCurrentAccountAsAMember() async throws {
        let backend = FakeBackend()
        try await backend.connect()
        let page = try await backend.browseSpaces(.init(scope: .discover), after: nil)
        let space = try #require(page.spaces.first)
        let result = try await backend.mutateConversation(
            .join,
            in: space.conversation.id,
            operationID: "member-join",
            expectedRevision: nil
        )
        let details = try #require(result.details)
        #expect(details.conversation.members == [FixtureWorld.minimal.me])
        #expect(!details.allowedActions.contains("setRole"))
        #expect(!details.allowedActions.contains("identity"))
        let people = try await backend.participants(in: space.conversation.id, after: nil)
        #expect(people.participants.first?.role == .member)
    }
}

extension ConversationManagementTests {
    @Test func aPendingRequestStaysVisibleWithoutBecomingJoined() async throws {
        let backend = FakeBackend()
        try await backend.connect()
        let page = try await backend.browseSpaces(.init(scope: .discover), after: nil)
        let space = try #require(page.spaces.first { $0.allowedActions.contains("requestJoin") })
        let result = try await backend.mutateConversation(
            .requestJoin,
            in: space.conversation.id,
            operationID: "request",
            expectedRevision: nil
        )
        #expect(result.details?.membership == .requested)
        let after = try await backend.browseSpaces(.init(scope: .discover), after: nil)
        #expect(after.spaces.first { $0.conversation.id == space.conversation.id }?.membership == .requested)
        let joined = try await backend.browseSpaces(.init(scope: .joined), after: nil)
        #expect(!joined.spaces.contains { $0.conversation.id == space.conversation.id })
    }
}
