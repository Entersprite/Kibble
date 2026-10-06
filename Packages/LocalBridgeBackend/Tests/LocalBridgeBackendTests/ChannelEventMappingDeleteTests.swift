import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `MESSAGE_DELETED` (type 8) becoming a tombstone event (edit spec §3).
/// Whether Google sends it, or only a `MESSAGE_UPDATED` carrying
/// `delete_time`, is `[Verify]`; both end as a tombstone.
///
/// The builders are `ChannelEventMappingTests`' own, copied because they are
/// `private` there and that file is near swiftlint's ceiling. `EventBody`
/// field 18 is `message_deleted`; `MessageDeletedEvent` field 1 is the
/// `MessageId` (vendored proto :1504, :1771).
struct ChannelEventMappingDeleteTests {
    private func padded(_ fields: [Int: String], upTo count: Int) -> String {
        let joined = (1 ... count).map { fields[$0] ?? "null" }.joined(separator: ",")
        return "[" + joined + "]"
    }

    private func quoted(_ text: String) -> String {
        "\"" + text + "\""
    }

    /// `[[null,null,null,[null,"<topic>",[null,null,["<dm>"]]]],"<id>"]`
    private func messageID(
        _ id: String,
        topic: String = "t-1",
        space: String? = nil,
        dm: String? = "dm-1"
    ) -> String {
        var groupFields: [Int: String] = [:]
        if let space {
            groupFields[1] = padded([1: quoted(space)], upTo: 1)
        }
        if let dm {
            groupFields[3] = padded([1: quoted(dm)], upTo: 1)
        }
        let groupID = padded(groupFields, upTo: 3)
        let topicID = padded([2: quoted(topic), 3: groupID], upTo: 3)
        let parent = padded([4: topicID], upTo: 4)
        return "[" + parent + "," + quoted(id) + "]"
    }

    private func event(_ bodies: [String]) throws -> ChannelEvent {
        let padding = Array(repeating: "null", count: 7).joined(separator: ",")
        let list = "[" + bodies.joined(separator: ",") + "]"
        let json = "[[[" + padding + "," + list + "],\"wrapper-id\"]]"
        let value = try PBLiteValue(json: Data(json.utf8))
        return try #require(ChannelEvent(ChannelArray(aid: 1, data: value)))
    }

    private func mapped(_ bodies: [String]) throws -> [ChatEvent] {
        try ChannelEventMapping.chatEvents(from: event(bodies))
    }

    private func deletedBody(_ messageID: String?) -> String {
        var fields = [12: "8"]
        if let messageID {
            fields[18] = padded([1: messageID], upTo: 1)
        }
        return padded(fields, upTo: 18)
    }

    @Test func aDeletedEventBecomesATombstoneEvent() throws {
        let events = try mapped([deletedBody(messageID("m-1", space: "s-1", dm: nil))])
        #expect(events == [.messageDeleted(id: ChatKit.Message.ID("m-1"), in: Conversation.ID("space/s-1"))])
    }

    /// Guard: no id, no event - routed, never a tombstone for "".
    @Test func aDeletedEventWithNoMessageIsRouted() throws {
        let events = try mapped([deletedBody(messageID("", space: "s-1", dm: nil))])
        guard case .unknown = events.first else {
            Issue.record("expected .unknown, got \(String(describing: events.first))")
            return
        }
    }
}
