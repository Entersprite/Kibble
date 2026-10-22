import ChatAPI
import ChatKit
import Foundation
import Testing
@testable import ChatService

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CallDirectoryContinuityTests {
    @Test func canonicalDirectoryChangesReachTheServiceOwnedListenerWithoutAClientHint() async throws {
        let harness = try await CallHarness.make()
        let account = harness.accounts[0]
        let runtime = try #require(await harness.service.runtimes[account.id])
        let source = try #require(await harness.providers.source(account.id, device: .init("one")))
        let original = source.recipients
        let peer = Member(id: .init("new-peer"), kind: .human, displayName: "New Peer")
        let conversation = Conversation(
            id: .init("new-dm"), kind: .directMessage, members: [account.selfID, peer.id]
        )
        do {
            try await runtime.appendAndPublish(.membersResolved([peer]), live: false)
            try await runtime.appendAndPublish(.conversationUpdated(conversation), live: false)
            try await callEventually { source.recipients.contains { $0.conversationID == conversation.id } }
            #expect(original.allSatisfy { source.recipients.contains($0) })
            let added = try #require(source.recipients.first { $0.conversationID == conversation.id })
            let id = try #require(source.receiveIncoming(from: added))
            try await callEventually { try await harness.read(account).call?.id == id }
            try await runtime.appendAndPublish(
                .conversationRemoved(conversationID: conversation.id, historyBefore: nil), live: false
            )
            try await callEventually { !source.recipients.contains(added) }
        } catch {
            await harness.service.shutdown()
            throw error
        }
        await harness.service.shutdown()
    }
}
