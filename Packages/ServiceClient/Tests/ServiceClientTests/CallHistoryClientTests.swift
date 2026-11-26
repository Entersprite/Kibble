import ChatAPI
import ChatKit
import Foundation
import InProcessChatTransport
import ServiceClient
import Testing
@testable import ChatService

@Suite(.timeLimit(.minutes(1)))
struct CallHistoryClientTests {
    @Test func retainedHistoryIsSerializedAndScopedToTheOriginalAccountBinding() async throws {
        let harness = try await ClientHarness.make()
        let backend = harness.backend(harness.first)
        let first = try await harness.canonical(harness.first.id)
        let second = try await harness.canonical(harness.second.id)
        let one = sample(reference: "first-call")
        let two = sample(reference: "second-call")
        _ = try first.append(.messageReceived(one), live: false)
        _ = try second.append(.messageReceived(two), live: false)
        try await backend.connect()
        #expect(backend.capabilities.canReadCallHistory)
        let history: any CallHistoryBackend = backend
        #expect(try await history.callHistory(.init()).messages == [one])
        #expect(try await harness.backend(harness.second).callHistory().messages == [two])

        let restricted = AccountClient(transport: InProcessChatTransport(
            endpoint: harness.service, context: ServiceSessionContext(
                principalID: harness.context.principalID, deviceID: harness.context.deviceID,
                sessionID: .init("restricted"), accounts: [harness.second.id]
            )
        ))
        await #expect(throws: ServiceFailure.notAuthorized) {
            try await restricted.call(
                ReadCallHistory(), account: harness.first.id, revision: harness.first.revision
            )
        }
        _ = try first.append(.messageDeleted(id: one.id, in: one.conversationID), live: false)
        #expect(try await history.callHistory(.init()).messages.isEmpty)
        await backend.disconnect()
        await harness.service.shutdown()
    }

    @Test func malformedOrExcessiveQueriesAreRefusedThroughTheSerializer() async throws {
        let harness = try await ClientHarness.make()
        let backend = harness.backend(harness.first)
        for query in [CallHistoryQuery(limit: 0), .init(limit: 101), .init(cursor: "invalid")] {
            await #expect(throws: ServiceFailure.invalidRequest) {
                try await backend.callHistory(query)
            }
        }
        await harness.service.shutdown()
    }

    private func sample(reference: String) -> Message {
        Message(
            id: .init("same-message"), conversationID: .init("same"), threadID: .init("same-thread"),
            sender: .init("peer"), text: "", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            callStatus: .ended, callMetadata: .init(reference: reference)
        )
    }
}
