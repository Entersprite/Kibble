import ChatAPI
import Foundation
import Testing

struct CallHistoryWireTests {
    @Test func retainedHistoryQueryHasAnAccountScopedStableWireShape() throws {
        let request = try ServiceRequest(
            header: .init(requestID: .init("request-1"), accountID: .init("account")),
            payload: ReadCallHistory()
        )
        let bytes = try ServiceCodec.encode(request)
        let url = try #require(Bundle.module.url(
            forResource: "read-call-history", withExtension: "json", subdirectory: "Golden"
        ))
        let expected = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .newlines)
        #expect(String(decoding: bytes, as: UTF8.self) == expected)
        #expect(try ServiceCodec.decode(ServiceRequest.self, from: bytes).decodePayload(ReadCallHistory.self)
            == ReadCallHistory())
        #expect(throws: ServiceFailure.accountRequired) {
            try ServiceRequest(header: .init(requestID: .init("request-1")), payload: ReadCallHistory())
        }
    }
}
