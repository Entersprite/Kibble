import ChatAPI
import ChatKit
import ChatService
import Foundation
import Testing

struct CardActionOperationTests {
    @Test func callbacksCrossSerializationAndKeepTheirOriginalOperationResult() async throws {
        let harness = try await ServiceHarness.make(includeCardActions: true)
        let operation = ServiceOperationID("card-action")
        var action = AppCardActionRequest(
            conversation: .init("same-conversation"),
            thread: .init("thread"),
            message: .init("card"),
            action: AppCardAction(
                id: "action",
                label: "Acknowledge"
            )
        )
        let payload = InvokeCardAction(action: action, operationID: operation)
        let first = try await harness.call(payload, account: harness.first.id)
        #expect(first.card?.sections.first?.widgets.isEmpty == false)
        let status = try await harness.call(GetOperation(operationID: operation), account: harness.first.id)
        #expect(status.state == "succeeded")
        #expect(try await harness.call(payload, account: harness.first.id) == first)
        action.action.id = "different"
        await #expect(throws: ServiceFailure.operationConflict) {
            _ = try await harness.call(
                InvokeCardAction(action: action, operationID: operation),
                account: harness.first.id
            )
        }
        await #expect(throws: ServiceFailure.operationUnknown) {
            _ = try await harness.call(GetOperation(operationID: operation), account: harness.second.id)
        }
        await harness.service.shutdown()
    }
}
