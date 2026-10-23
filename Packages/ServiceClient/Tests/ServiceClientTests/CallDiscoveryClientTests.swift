import ChatAPI
import ChatKit
import InProcessChatTransport
import ServiceClient
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct CallDiscoveryClientTests {
    @Test func discoveryCrossesTheSerializerAndCannotEscapeAccountAuthorization() async throws {
        let harness = try await ClientHarness.make()
        let backend = harness.backend(harness.first)
        try await backend.connect()
        #expect(backend.capabilities.canDiscoverCalls)
        let calls: any CallDiscoveryBackend = backend
        let value = try await calls.callAvailability(in: .init("same"))
        #expect(value.conversationID == .init("same"))
        #expect(value.status == .unknown("unavailable"))
        let restricted = AccountClient(transport: InProcessChatTransport(
            endpoint: harness.service, context: ServiceSessionContext(
                principalID: harness.context.principalID, deviceID: harness.context.deviceID,
                sessionID: .init("restricted"), accounts: [harness.second.id]
            )
        ))
        await #expect(throws: ServiceFailure.notAuthorized) {
            try await restricted.call(
                GetCallAvailability(conversationID: .init("same")),
                account: harness.first.id, revision: harness.first.revision
            )
        }
        await backend.disconnect()
        await harness.service.shutdown()
    }
}
