import ChatAPI
import ChatKit
import ChatService
import Foundation
import InProcessChatTransport
import ServiceClient
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CallConnectionRecoveryTests {
    @Test func serializedCallObserverRecoversWithoutAProviderStateChangeOrRestartCommand() async throws {
        let harness = try await CallHarness.make()
        let account = harness.accounts[0]
        let endpoint = InterruptedCallReadEndpoint(service: harness.service)
        let client = AccountClient(transport: InProcessChatTransport(
            endpoint: endpoint, context: ServiceSessionContext(
                principalID: .init("owner"), deviceID: .init("one"), sessionID: .init("recovery-client"),
                accounts: [account.id]
            )
        ))
        let facade = try ServiceAudioCallService(account: AccountSummary(
            id: account.id, selfID: account.selfID, label: account.label,
            connection: .connected, revision: account.currentRevision
        ), client: client)
        var states: [Bool] = []
        let reader = Task {
            for await event in facade.events {
                if case let .listenerChanged(listening) = event {
                    states.append(listening)
                }
            }
        }
        try await facade.startListening()
        try await callEventually { states == [true, false, true] }
        let versions = await endpoint.versions
        #expect(versions.count >= 2 && versions[0] == versions[1])
        #expect(await endpoint.operations.allSatisfy { $0 == ReadCallState.operation })
        #expect(await Array(endpoint.waits.prefix(3)) == [0, 20000, 0])
        await facade.stop()
        reader.cancel()
        await reader.value
        await harness.service.shutdown()
    }
}

private actor InterruptedCallReadEndpoint: ServiceEndpoint {
    let service: ChatService
    var operations: [String] = []
    var versions: [String] = []
    var waits: [Int] = []
    private var count = 0

    init(service: ChatService) {
        self.service = service
    }

    func handle(_ data: Data, context: ServiceSessionContext) async throws -> Data {
        let request = try ServiceCodec.decode(ServiceRequest.self, from: data)
        operations.append(request.operation)
        try waits.append(request.decodePayload(ReadCallState.self).waitMilliseconds)
        count += 1
        if count == 2 {
            throw ServiceFailure.overloaded
        }
        let result = try await service.handle(data, context: context)
        let response = try ServiceCodec.decode(ServiceResponse.self, from: result)
        if case let .success(payload) = response.result {
            try versions.append(ServiceCodec.decode(ServiceCallState.self, from: payload).version)
        }
        return result
    }
}
