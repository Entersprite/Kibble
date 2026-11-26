import Foundation
import Testing
@testable import ChatKit

@Suite("Timestamp precision")
struct TimestampPrecisionTests {
    @Test(arguments: [
        "2026-10-19T10:15:30.000001Z",
        "2026-10-19T10:15:30.123456Z",
        "1969-12-31T23:59:59.999999Z"
    ])
    func fractionalReadPositionSurvivesTheWire(_ raw: String) throws {
        let date = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw)
        let command = ChatCommand.markRead(conversationID: Conversation.ID("space/shared"), upTo: date)
        let encoded = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(ChatCommand.self, from: encoded)
        guard case let .markRead(_, restored) = decoded else {
            Issue.record("Expected a read position")
            return
        }
        #expect(abs(restored.timeIntervalSince(date)) < 0.000_000_5)
        #expect(try RFC3339.string(from: date) == raw)
    }

    @Test(arguments: [
        "2026-10-19T10:15:30.000Z",
        "2026-10-19T10:15:30.123Z",
        "2026-10-19T10:15:30.999Z"
    ])
    func existingMillisecondEncodingStaysStable(_ raw: String) throws {
        let date = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw)
        #expect(try RFC3339.string(from: date) == raw)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, 1e300, -1e300])
    func invalidTimestampsThrowInsteadOfTrapping(_ timestamp: Double) {
        let date = Date(timeIntervalSince1970: timestamp)
        #expect(throws: EncodingError.self) { try RFC3339.string(from: date) }
    }

    @Test
    func roundingCanCarryIntoTheNextSecond() throws {
        let date = try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse("2026-10-19T23:59:59.9999999Z")
        #expect(try RFC3339.string(from: date) == "2026-10-20T00:00:00.000Z")
    }
}
