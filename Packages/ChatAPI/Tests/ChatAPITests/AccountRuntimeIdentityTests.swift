import ChatAPI
import ChatKit
import Foundation
import Testing

struct AccountRuntimeIdentityTests {
    @Test func runtimeIdentityIsAdditiveAndRoundTrips() throws {
        let runtimeID = UUID()
        let summary = AccountSummary(
            id: ConnectedAccountID("account"), selfID: Member.ID("self"), label: "Acme",
            connection: .connected, runtimeID: runtimeID
        )
        let bytes = try ServiceCodec.encode(summary)
        #expect(try ServiceCodec.decode(AccountSummary.self, from: bytes) == summary)
        var legacy = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        legacy["runtimeID"] = nil
        let decoded = try ServiceCodec.decode(
            AccountSummary.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(decoded.runtimeID == nil)
        #expect(decoded.id == summary.id)
    }
}
