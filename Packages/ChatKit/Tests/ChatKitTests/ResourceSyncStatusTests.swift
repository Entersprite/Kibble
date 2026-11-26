import Foundation
import Testing
@testable import ChatKit

struct ResourceSyncStatusTests {
    @Test func knownStatusRoundTripsAndUnknownResourceAndPhaseRemainIntact() throws {
        let status = ResourceSyncStatus(
            resource: .init(rawValue: "futureResource"), conversationID: .init("opaque"),
            phase: .init(rawValue: "futurePhase"), error: .unknown("fixture")
        )
        let event = ChatEvent.resourceSyncChanged(status)
        #expect(try JSONDecoder().decode(ChatEvent.self, from: JSONEncoder().encode(event)) == event)
    }

    @Test func absentDirectoryCoverageDoesNotClaimCompleteness() throws {
        let data = Data(#"{"conversations":[]}"#.utf8)
        let snapshot = try JSONDecoder().decode(ConversationSnapshot.self, from: data)
        #expect(!snapshot.isComplete)
        #expect(snapshot.removedIDs.isEmpty)
    }
}
