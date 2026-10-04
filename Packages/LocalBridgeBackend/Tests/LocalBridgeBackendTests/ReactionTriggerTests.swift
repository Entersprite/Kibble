import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `MESSAGE_REACTED` (type 24) naming the message and topic to refetch.
///
/// Helpers copied from `ChannelEventMappingReadStateTests`'s own stated
/// convention: `private` is `private`, and a little duplication is cheaper
/// than a shared surface neither file needs elsewhere.
struct ReactionTriggerTests {
    // MARK: - Building a body in the shape the wire actually uses

    private func padded(_ fields: [Int: String], upTo count: Int) -> String {
        let joined = (1 ... count).map { fields[$0] ?? "null" }.joined(separator: ",")
        return "[" + joined + "]"
    }

    private func quoted(_ text: String) -> String {
        "\"" + text + "\""
    }

    private func event(_ bodies: [String]) throws -> ChannelEvent {
        let padding = Array(repeating: "null", count: 7).joined(separator: ",")
        let list = "[" + bodies.joined(separator: ",") + "]"
        let json = "[[[" + padding + "," + list + "],\"wrapper-id\"]]"
        let value = try PBLiteValue(json: Data(json.utf8))
        return try #require(ChannelEvent(ChannelArray(aid: 1, data: value)))
    }

    // MARK: - MESSAGE_REACTED

    /// `EventBody` field 22 is `message_reaction`; `MessageReactionEvent` 1 is
    /// `message_id`; `MessageId` 1 parent / 2 id; `MessageParentId` 4 topic;
    /// `TopicId` 2 id / 3 group; `GroupId` 1 space; `SpaceId` 1. Field numbers
    /// from the vendored proto, values invented.
    ///
    /// `group` defaults to space `s-1`; pass the all-null shape
    /// (`padded([:], upTo: 3)`) to name a group with neither a space nor a
    /// DM id, which is the shape `aGroupNamingNeitherASpaceNorADMIsNoTrigger`
    /// below needs.
    private func reactedBody(
        type: Int = 24, messageID: String? = "m-1", topicID: String? = "t-1", group: String? = nil
    ) -> String {
        let resolvedGroup = group ?? padded([1: padded([1: quoted("s-1")], upTo: 1)], upTo: 3)
        let topic = padded([2: topicID.map(quoted), 3: resolvedGroup].compactMapValues { $0 }, upTo: 3)
        let identifier = padded(
            [1: padded([4: topic], upTo: 4), 2: messageID.map(quoted)].compactMapValues { $0 },
            upTo: 2
        )
        let reaction = padded([1: identifier], upTo: 1)
        return padded([12: String(type), 22: reaction], upTo: 22)
    }

    private func reacted(_ body: String) throws -> ReactedMessage? {
        try event([body]).bodies.first.flatMap(ChannelEventMapping.reactedMessage(in:))
    }

    @Test func aReactionEventNamesItsMessageAndTopic() throws {
        let target = try #require(try reacted(reactedBody()))
        #expect(target.messageID == ChatKit.Message.ID("m-1"))
        #expect(target.parent.topicID.topicID == "t-1")
        #expect(target.parent.topicID.groupID.spaceID.spaceID == "s-1")
    }

    /// The tag is the identity (`findings.md` §12.1.3).
    @Test func theSameBodyUnderAnotherTagIsNoTrigger() throws {
        #expect(try reacted(reactedBody(type: 99)) == nil)
    }

    @Test(arguments: [(String?.none, Optional("t-1")), (Optional("m-1"), String?.none)])
    func aReactionWithoutAnAddressIsNoTrigger(_ messageID: String?, _ topicID: String?) throws {
        #expect(try reacted(reactedBody(messageID: messageID, topicID: topicID)) == nil)
    }

    /// Final review: every other test here uses space `s-1`, so
    /// `reactedMessage(in:)`'s `conversationID(...) != nil` condition had no
    /// test that could fail without it. A `GroupId` naming neither a space
    /// nor a DM - `conversationID(_:)`'s `default: nil` branch - names
    /// nowhere to refetch from.
    @Test func aGroupNamingNeitherASpaceNorADMIsNoTrigger() throws {
        let noGroup = padded([:], upTo: 3)
        #expect(try reacted(reactedBody(group: noGroup)) == nil)
    }

    /// Nothing is dropped: the event still maps to `.unknown` as before.
    @Test func theEventIsStillRouted() throws {
        let events = try ChannelEventMapping.chatEvents(from: event([reactedBody()]))
        guard case let .unknown(type, _) = events.first else {
            Issue.record("expected .unknown")
            return
        }
        #expect(type == "googlechat.eventType.24")
    }
}
