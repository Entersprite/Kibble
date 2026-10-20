import Foundation
import Testing
@testable import ChatKit

struct ClientOperationIDTests {
    @Test func stableBirthIsPartOfAnOpaqueUniqueIdentity() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.125)
        let first = ClientOperationID.make(at: date)
        let second = ClientOperationID.make(at: date)
        #expect(first != second)
        #expect(ClientOperationID.createdAt(first) == date)
        #expect(first.utf8.count < 64)
    }

    @Test(arguments: [
        "legacy",
        "op1:bad:id",
        "op1:001:00000000-0000-0000-0000-000000000001",
        "op1:-1:00000000-0000-0000-0000-000000000001"
    ])
    func ambiguousBirthEncodingsAreNeverAcceptedAsTimedIDs(_ value: String) {
        #expect(ClientOperationID.createdAt(value) == nil)
    }
}
