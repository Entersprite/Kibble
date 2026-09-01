import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Wire events becoming domain events.
///
/// The pblite shapes below are **not invented**. Every field number was read off
/// the generated proto and then checked against the redacted captures in
/// `GChatBridgeCore`'s `Fixtures/shape/`, which record exactly which fields a
/// real `MESSAGE_POSTED` populates:
///
/// ```
/// EventBody      12 = event_type, 6 = message_posted
/// MessageEvent    1 = message
/// Message         1 = id, 2 = creator, 3 = create_time, 10 = text_body
/// MessageId       1 = parent_id, 2 = message_id
/// MessageParentId 4 = topic_id
/// TopicId         2 = topic_id, 3 = group_id
/// GroupId         1 = space_id, 3 = dm_id
/// ```
///
/// So the values here are made up and the syntax is Google's, which is the only
/// arrangement session 6's rule allows.
struct ChannelEventMappingTests {
    // MARK: - Building a body in the shape the wire actually uses

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

    private func message(
        id: String = "m-1",
        sender: String = "u-1",
        createdAtMicros: String = "1700000000000000",
        text: String = "hello",
        topic: String = "t-1",
        space: String? = nil,
        dm: String? = "dm-1"
    ) -> String {
        let creator = padded([1: padded([1: quoted(sender)], upTo: 1)], upTo: 1)
        return padded([
            1: messageID(id, topic: topic, space: space, dm: dm),
            2: creator,
            3: quoted(createdAtMicros),
            10: quoted(text)
        ], upTo: 10)
    }

    private func body(type: Int, message: String? = nil) -> String {
        var fields: [Int: String] = [12: String(type)]
        if let message {
            fields[6] = padded([1: message], upTo: 1) // MessageEvent field 1
        }
        return padded(fields, upTo: 12)
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

    // MARK: - A posted message

    @Test func aPostedMessageBecomesAReceivedMessage() throws {
        let events = try mapped([body(type: 6, message: message())])
        guard case let .messageReceived(message) = events.first else {
            Issue.record("expected .messageReceived, got \(String(describing: events.first))")
            return
        }
        #expect(message.id.rawValue == "m-1")
        #expect(message.sender.rawValue == "u-1")
        #expect(message.text == "hello")
    }

    /// `create_time` is microseconds since the epoch, and arrives as a **string**
    /// because pblite sends 64-bit values that way — a 16-digit number does not
    /// survive JSON's binary64.
    @Test func createTimeIsMicrosecondsAndArrivesAsAString() throws {
        let events = try mapped([
            body(type: 6, message: message(createdAtMicros: "1700000000000000"))
        ])
        guard case let .messageReceived(message) = events.first else {
            Issue.record("expected .messageReceived")
            return
        }
        #expect(message.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func theThreadIsTheTopicTheMessageWasPostedIn() throws {
        let events = try mapped([body(type: 6, message: message())])
        guard case let .messageReceived(message) = events.first else {
            Issue.record("expected .messageReceived")
            return
        }
        #expect(message.threadID.rawValue == "t-1")
    }

    /// A space id and a DM id come from different namespaces on the wire, so
    /// they are prefixed rather than flattened — two conversations sharing a
    /// raw id would otherwise merge into one.
    @Test func aDirectMessageAndASpaceCannotCollide() throws {
        let dm = try mapped([body(type: 6, message: message())])
        guard case let .messageReceived(message) = dm.first else {
            Issue.record("expected .messageReceived")
            return
        }
        #expect(message.conversationID.rawValue == "dm/dm-1")
    }

    @Test func aSpaceMessageIsPrefixedAsASpace() throws {
        let spaceMessage = message(id: "m-9", sender: "u-9", topic: "t-9", space: "s-1", dm: nil)
        let events = try mapped([body(type: 6, message: spaceMessage)])
        guard case let .messageReceived(message) = events.first else {
            Issue.record("expected .messageReceived")
            return
        }
        #expect(message.conversationID.rawValue == "space/s-1")
    }

    @Test func anEditedMessageBecomesAnUpdate() throws {
        let events = try mapped([body(type: 7, message: message(text: "edited"))])
        guard case let .messageUpdated(message) = events.first else {
            Issue.record("expected .messageUpdated, got \(String(describing: events.first))")
            return
        }
        #expect(message.text == "edited")
    }

    @Test func anEmptyTextBodyIsAnEmptyStringRatherThanAFailure() throws {
        let events = try mapped([body(type: 6, message: message(text: ""))])
        guard case let .messageReceived(message) = events.first else {
            Issue.record("expected .messageReceived")
            return
        }
        #expect(message.text.isEmpty)
    }

    // MARK: - Everything else is routed, never dropped

    /// §12.1.1's rule. The four tags past the vendored proto's enum must arrive
    /// as events rather than vanishing.
    @Test func aTagTheProtoCannotNameBecomesAnUnknownEvent() throws {
        let events = try mapped([body(type: 64)])
        guard case let .unknown(type, _) = events.first else {
            Issue.record("expected .unknown, got \(String(describing: events.first))")
            return
        }
        #expect(type == "googlechat.eventType.64")
    }

    /// A type the proto *can* name but this mapping does not handle is routed
    /// the same way. Being nameable is not the same as being mapped, and
    /// pretending otherwise loses events quietly.
    @Test func aKnownButUnmappedTypeIsAlsoRouted() throws {
        let events = try mapped([body(type: 33)]) // SESSION_READY
        guard case let .unknown(type, _) = events.first else {
            Issue.record("expected .unknown")
            return
        }
        #expect(type == "googlechat.eventType.33")
    }

    @Test func anUntaggedBodyIsRoutedRatherThanDiscarded() throws {
        let events = try mapped(["[null,null]"])
        guard case let .unknown(type, _) = events.first else {
            Issue.record("expected .unknown")
            return
        }
        #expect(type == "googlechat.eventType.untagged")
    }

    /// A `MESSAGE_POSTED` whose message cannot be built is routed as unknown
    /// rather than becoming a `Message` with invented fields. A message with an
    /// empty id would be indistinguishable from a real one in the store.
    @Test func aMessageBodyMissingItsIdentityIsRoutedRatherThanFabricated() throws {
        let events = try mapped([body(type: 6, message: "[null]")])
        guard case let .unknown(type, _) = events.first else {
            Issue.record("expected .unknown, got \(String(describing: events.first))")
            return
        }
        #expect(type == "googlechat.eventType.6")
    }

    @Test func theUnknownPayloadCarriesTheBody() throws {
        let events = try mapped([body(type: 64)])
        guard case let .unknown(_, payload) = events.first else {
            Issue.record("expected .unknown")
            return
        }
        #expect(payload != .null)
    }

    // MARK: - Nothing is lost

    @Test func everyBodyProducesExactlyOneEvent() throws {
        let events = try mapped([
            body(type: 6, message: message()),
            body(type: 33),
            body(type: 64),
            body(type: 7, message: message())
        ])
        #expect(events.count == 4)
    }

    @Test func anEventWithNoBodiesProducesNoEvents() throws {
        #expect(try mapped([]).isEmpty)
    }
}
