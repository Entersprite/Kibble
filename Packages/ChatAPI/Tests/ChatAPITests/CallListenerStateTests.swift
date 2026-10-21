import ChatAPI
import Foundation
import Testing

struct CallListenerStateTests {
    @Test func startupStateRoundTripsAndOlderSnapshotsKeepTheirMeaning() throws {
        let state = ServiceCallState(version: UUID().uuidString + ":0", isListenerStarting: true)
        let data = try ServiceCodec.encode(state)
        #expect(try ServiceCodec.decode(ServiceCallState.self, from: data) == state)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy["isListenerStarting"] = nil
        let decoded = try ServiceCodec.decode(
            ServiceCallState.self, from: JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(!decoded.isListenerStarting)
        #expect(!decoded.isListening)
    }
}
