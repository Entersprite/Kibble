import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `GROUP_VIEWED` becoming a read position.
///
/// Split out of `ChannelEventMappingTests` (that file's own former
/// `// MARK: - GROUP_VIEWED` section) once Task 4's mapping change and its
/// five covering tests pushed that file past swiftlint's 400-line ceiling.
/// The helpers below are copies of `ChannelEventMappingTests`'s own private
/// ones - `private` is `private`, and a little duplication is cheaper than a
/// shared surface neither file actually needs elsewhere (the same trade
/// `SendMessageTests`' `RoutingTransport` doc comment states, and the one
/// `LiveChannelTests`/`LiveChannelFailureTests` already make for `shell()`
/// and `messageChunk`).
struct ChannelEventMappingReadStateTests {
    // MARK: - Building a body in the shape the wire actually uses

    private func padded(_ fields: [Int: String], upTo count: Int) -> String {
        let joined = (1 ... count).map { fields[$0] ?? "null" }.joined(separator: ",")
        return "[" + joined + "]"
    }

    private func quoted(_ text: String) -> String {
        "\"" + text + "\""
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

    // MARK: - GROUP_VIEWED

    /// `EventBody` field 3 is `group_viewed`; `GroupViewedEvent` is
    /// `1 = group_id`, `2 = view_time`. Field numbers read off the generated
    /// proto, values invented - the arrangement session 6's rule requires.
    private func groupViewedBody(
        type: Int = 3,
        space: String? = nil,
        dm: String? = "dm-1",
        viewTimeMicros: String? = "1700000000000000"
    ) -> String {
        var groupFields: [Int: String] = [:]
        if let space {
            groupFields[1] = padded([1: quoted(space)], upTo: 1)
        }
        if let dm {
            groupFields[3] = padded([1: quoted(dm)], upTo: 1)
        }
        let viewed = padded(
            [1: padded(groupFields, upTo: 3), 2: viewTimeMicros.map(quoted)].compactMapValues { $0 },
            upTo: 2
        )
        return padded([3: viewed, 12: String(type)], upTo: 12)
    }

    @Test func aViewedGroupBecomesReadStateChanged() throws {
        let events = try mapped([groupViewedBody()])
        guard case let .readStateChanged(conversationID, lastReadAt, unread) = events.first else {
            Issue.record("expected .readStateChanged, got \(String(describing: events.first))")
            return
        }
        #expect(conversationID.rawValue == "dm/dm-1")
        #expect(lastReadAt == Date(timeIntervalSince1970: 1_700_000_000))
        // The event carries no count - viewing is what clears it, so 0 is the
        // inference, recorded as `[Verify]` in findings rather than assumed
        // silently.
        #expect(unread == 0)
    }

    @Test func aViewedSpaceKeepsTheSpaceNamespace() throws {
        let events = try mapped([groupViewedBody(space: "s-1", dm: nil)])
        guard case let .readStateChanged(conversationID, _, _) = events.first else {
            Issue.record("expected .readStateChanged")
            return
        }
        #expect(conversationID.rawValue == "space/s-1")
    }

    /// **The tag is the identity, never the body.** `findings.md` §12.1.3: body
    /// field numbers are not type numbers, and a mapper that switched on the
    /// decoded body would file this as a read - silently, and in a way no
    /// round-trip test would catch. This body decodes perfectly as a
    /// `GroupViewedEvent` and must still be routed as unknown.
    @Test func aGroupViewedBodyUnderAnotherTagDoesNotMap() throws {
        let events = try mapped([groupViewedBody(type: 99)])
        guard case let .unknown(type, _) = events.first else {
            Issue.record("expected .unknown, got \(String(describing: events.first))")
            return
        }
        #expect(type == "googlechat.eventType.99")
    }

    /// A `GROUP_VIEWED` whose group id is neither namespace has no
    /// conversation to name, and a fabricated one is worse than an honest
    /// `.unknown` - the same call `message(in:)` already makes.
    @Test func aViewedGroupWithNoIdentityIsRouted() throws {
        let events = try mapped([groupViewedBody(space: nil, dm: nil)])
        guard case .unknown = events.first else {
            Issue.record("expected .unknown, got \(String(describing: events.first))")
            return
        }
    }

    /// **Presence decides, never the value** (`WorldMapping.readPosition`'s
    /// rule). An absent `view_time` reads as 0, which is 1970: mapped, it
    /// would turn every mention in the conversation unread.
    @Test func aViewedGroupWithNoViewTimeIsRouted() throws {
        let events = try mapped([groupViewedBody(viewTimeMicros: nil)])
        guard case .unknown = events.first else {
            Issue.record("expected .unknown, got \(String(describing: events.first))")
            return
        }
    }

    /// Other people's read positions. There is no domain type and no UI for
    /// them, so this stays routed - asserted deliberately, so mapping it later
    /// is a decision rather than an accident.
    @Test func readReceiptChangedIsStillRouted() throws {
        let events = try mapped([body(type: 36)])
        guard case let .unknown(type, _) = events.first else {
            Issue.record("expected .unknown, got \(String(describing: events.first))")
            return
        }
        #expect(type == "googlechat.eventType.36")
    }
}
