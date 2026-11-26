import ChatAPI
import ChatKit
import ChatService
import Foundation
import InProcessChatTransport
import ServiceClient
import Testing

struct BindingClientTests {
    private struct Custody: AccountLinkCustody {
        func verify(_ link: AccountLinkRecord) -> VerifiedLinkIdentity {
            .init(
                selfID: Member.ID("first-self"),
                label: "First"
            )
        }

        func install(_ link: AccountLinkRecord) {}
        func discardStaging(_ link: AccountLinkRecord) {}
        func eraseGeneration(account: ConnectedAccountID, generation: String) {}
    }

    @Test func anExistingBackendCannotAdoptAReplacementLoginRevision() async throws {
        let harness = try await ClientHarness.make(linkCustody: Custody())
        let old = harness.backend(harness.first)
        let client = AccountClient(transport: InProcessChatTransport(
            endpoint: harness.service,
            context: harness.context
        ))
        _ = try await old.call(GetAccountPolicy())
        let link = try await client.beginLink(
            operationID: ServiceOperationID("reauth"),
            replacing: harness.first.id
        )
        _ = try await client.completeLink(link.id)
        await #expect(throws: ServiceFailure.staleAccount) { try await old.call(GetAccountPolicy()) }
        let current = try #require(try await client.accounts().first { $0.id == harness.first.id })
        #expect(current.revision != harness.first.revision)
        _ = try await harness.backend(current).call(GetAccountPolicy())
        await harness.service.shutdown()
    }
}
