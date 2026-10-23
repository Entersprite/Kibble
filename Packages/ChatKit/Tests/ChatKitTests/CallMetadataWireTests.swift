import Foundation
import Testing
@testable import ChatKit

struct CallMetadataWireTests {
    @Test func absentMetadataPreservesOldMessagesAndEmptyMetadataNormalizesToAbsent() throws {
        var message = sample()
        let encoder = JSONEncoder()
        #expect(try !String(decoding: encoder.encode(message), as: UTF8.self).contains("callMetadata"))
        let old = try JSONDecoder().decode(Message.self, from: encoder.encode(message))
        #expect(old.callMetadata == nil)
        message = sample(metadata: .init())
        #expect(message.callMetadata == nil)
    }

    @Test func historicalMetadataSurvivesMessageFramesWithWireDates() throws {
        let metadata = MessageCallMetadata(
            reference: "opaque-call", joinURL: URL(string: "https://example.test/call"),
            endedAt: Date(timeIntervalSince1970: 1_700_000_000.125),
            participantsChangedAt: Date(timeIntervalSince1970: 1_700_000_001.250)
        )
        let message = sample(metadata: metadata)
        try expectWireStable(message, golden: "message-call-metadata")
        let bytes = try JSONEncoder().encode(ChatEvent.messageReceived(message))
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("2023-11-14T22:13:20.125Z"))
        #expect(try JSONDecoder().decode(ChatEvent.self, from: bytes) == .messageReceived(message))
    }

    @Test func missingCapabilityAndMalformedPagingNeverImplySupportOrAnEmptyHistory() throws {
        #expect(!Capabilities().canReadCallHistory)
        #expect(throws: CallHistoryError.self) {
            try CallHistoryPosition.decode(for: .init(limit: 0))
        }
        #expect(throws: CallHistoryError.self) {
            try CallHistoryPosition.decode(for: .init(cursor: "not base64"))
        }
    }

    private func sample(metadata: MessageCallMetadata? = nil) -> Message {
        Message(
            id: .init("message"), conversationID: .init("conversation"), threadID: .init("thread"),
            sender: .init("peer"), text: "", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            callStatus: .unknown("future"), callMetadata: metadata
        )
    }
}
