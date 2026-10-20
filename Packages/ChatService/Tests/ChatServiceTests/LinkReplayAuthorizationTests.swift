import ChatAPI
import ChatKit
import ChatService
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct LinkReplayAuthorizationTests {
    @Test func replayingAnExistingReconnectStillRequiresTheCurrentAccountGrant() async throws {
        let record = LinkHarness.existing()
        let harness = try await LinkHarness.make(records: [record])
        let begin = BeginAccountLink(operationID: .init(ClientOperationID.make()), targetAccountID: record.id)
        let original = try await harness.call(begin)
        let revoked = ServiceSessionContext(
            principalID: harness.context.principalID, deviceID: harness.context.deviceID,
            sessionID: .init("restricted"), accounts: [], canLinkAccounts: true
        )
        let request = try ServiceRequest(header: .init(requestID: .init(UUID().uuidString)), payload: begin)
        let bytes = try await harness.service.handle(ServiceCodec.encode(request), context: revoked)
        let response = try ServiceCodec.decode(ServiceResponse.self, from: bytes)
        #expect(throws: ServiceFailure.notAuthorized) { try response.value(for: BeginAccountLink.self) }
        #expect(try await harness.call(begin) == original)
        #expect(await harness.custody.installs == 0)
        await harness.service.shutdown()
    }
}
