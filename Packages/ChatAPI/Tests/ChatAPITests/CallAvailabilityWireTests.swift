import ChatAPI
import ChatKit
import Foundation
import Testing

struct CallAvailabilityWireTests {
    @Test func availabilityQueryHasAnAccountScopedStableWireShape() throws {
        let payload = GetCallAvailability(conversationID: .init("room"))
        let request = try ServiceRequest(
            header: .init(requestID: .init("request-1"), accountID: .init("account")), payload: payload
        )
        let bytes = try ServiceCodec.encode(request)
        let url = try #require(Bundle.module.url(
            forResource: "get-call-availability", withExtension: "json", subdirectory: "Golden"
        ))
        let expected = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .newlines)
        #expect(String(decoding: bytes, as: UTF8.self) == expected)
        #expect(try ServiceCodec.decode(ServiceRequest.self, from: bytes)
            .decodePayload(GetCallAvailability.self) == payload)
        #expect(throws: ServiceFailure.accountRequired) {
            try ServiceRequest(header: .init(requestID: .init("request-1")), payload: payload)
        }
    }

    @Test func legacyCallSourcesDoNotAcquireJoinSupportAndNewSourcesAdvertiseItExplicitly() throws {
        let legacy = Data(#"{"version":"source:1","isListening":true,"recipients":[]}"#.utf8)
        let decoded = try ServiceCodec.decode(ServiceCallState.self, from: legacy)
        #expect(decoded.supportsExistingJoin == nil)
        #expect(try !String(decoding: ServiceCodec.encode(decoded), as: UTF8.self)
            .contains("supportsExistingJoin"))
        let current = ServiceCallState(version: "source:2", supportsExistingJoin: true)
        #expect(try ServiceCodec.decode(ServiceCallState.self, from: ServiceCodec.encode(current)) == current)
    }
}
