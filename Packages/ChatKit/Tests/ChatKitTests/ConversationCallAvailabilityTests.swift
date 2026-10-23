import ChatKit
import Foundation
import Testing

struct ConversationCallAvailabilityTests {
    @Test func availabilityHasAnExplicitFreshnessBoundAndPreservesUnknownStates() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let value = ConversationCallAvailability(
            conversationID: .init("room"), status: .unknown("future-status"), checkedAt: date,
            participants: [.init(memberID: .init("peer")), .init(displayName: "Guest")], totalParticipants: 3
        )
        let bytes = try JSONEncoder().encode(value)
        #expect(String(decoding: bytes, as: UTF8.self).contains("2023-11-14T22:13:20"))
        #expect(try JSONDecoder().decode(ConversationCallAvailability.self, from: bytes) == value)
        #expect(value.isFresh(at: date.addingTimeInterval(5), maximumAge: 10))
        #expect(!value.isFresh(at: date.addingTimeInterval(11), maximumAge: 10))
        #expect(!value.isFresh(at: date.addingTimeInterval(-1), maximumAge: 10))
        #expect(!value.isFresh(at: date, maximumAge: .infinity))
        #expect(!Capabilities().canDiscoverCalls)
        let missing = ConversationCallAvailability(
            conversationID: .init("room"), status: .inactive, checkedAt: date
        )
        let decoded = try JSONDecoder().decode(
            ConversationCallAvailability.self, from: JSONEncoder().encode(missing)
        )
        #expect(decoded.participants == nil)
    }
}
