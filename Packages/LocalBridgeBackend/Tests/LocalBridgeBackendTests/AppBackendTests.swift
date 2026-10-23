import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@Suite(.timeLimit(.minutes(1)))
struct AppBackendTests {
    @Test func appSearchExcludesInstalledAppsAndMutationsRetainBotIDs() async throws {
        let transport = try WebhookTransport()
        await transport.enableApps()
        let backend = LocalBridgeBackend(cookies: SearchBackendSupport.cookies, transport: transport)
        try await backend.connect()
        try await SearchBackendSupport.waitForSelf(backend)
        let contract: any ChatBackend = backend
        do {
            let room = Conversation.ID("space/a")
            let apps = try await contract.conversationIntegrations(room).apps
            #expect(apps.count == 1 && apps[0].member.kind == .app)
            let found = try await contract.searchConversationApps("build", in: room)
            #expect(found.map(\.id) == [.init("available-app")])
            #expect(found.first?.description == "Build notifications")
            let result = try await contract.mutateConversation(
                .addApp(.init("available-app")), in: room, operationID: "add-app", expectedRevision: nil
            )
            #expect(result.isConfirmed)
            let direct = try await contract.openAppConversation(.init("available-app"), from: room)
            #expect(direct.kind == .appDirectMessage && direct.members.contains(.init("available-app")))
            await #expect(throws: ChatError.self) {
                _ = try await contract.openAppConversation(.init("missing-app"), from: room)
            }
            #expect(try await contract.mutateConversation(
                .addApp(.init("available-app")), in: room, operationID: "add-app", expectedRevision: nil
            ) == result)
            _ = try await contract.mutateConversation(
                .removeApp(.init("available-app")), in: room, operationID: "remove-app", expectedRevision: nil
            )
            #expect(await transport.writes == 2)
            await transport.revoke()
            await #expect(throws: ChatError.self) {
                _ = try await contract.mutateConversation(
                    .addApp(.init("available-app")), in: room, operationID: "revoked", expectedRevision: nil
                )
            }
            #expect(await transport.writes == 2)
        } catch {
            await backend.disconnect(); throw error
        }
        await backend.disconnect()
    }
}
