import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The thread pushes (threads spec §2.3), built in the pblite shape the wire
/// uses: a positional array, or a trailing `{field: value}` dictionary for a
/// high field number (`PBLiteDecoder` rule 3). Push 82's layout is §63.10's
/// measured `{1 topic, 2 count, 3 unread}`; pushes 4, 9 and 53 follow purple
/// and the bundle (§64), so their mapping is `[Verify]` until a live run.
struct ChannelEventMappingThreadTests {
    private func padded(_ fields: [Int: String], upTo count: Int) -> String {
        "[" + (1 ... count).map { fields[$0] ?? "null" }.joined(separator: ",") + "]"
    }

    private func quoted(_ text: String) -> String {
        "\"" + text + "\""
    }

    /// `TopicId {2: topic, 3: GroupId {1: SpaceId {1: id}}}`.
    private func topicID(_ topic: String = "t-1", space: String = "s-1") -> String {
        let group = padded([1: padded([1: quoted(space)], upTo: 1)], upTo: 3)
        return padded([2: quoted(topic), 3: group], upTo: 3)
    }

    private func body(type: Int, field: Int, payload: String, trailing: Bool = false) -> String {
        if trailing {
            return padded([12: String(type)], upTo: 12).dropLast() + ",{\"\(field)\":\(payload)}]"
        }
        return padded([field: payload, 12: String(type)], upTo: max(field, 12))
    }

    private func mapped(_ body: String) throws -> ChatEvent? {
        let padding = Array(repeating: "null", count: 7).joined(separator: ",")
        let json = "[[[" + padding + ",[" + body + "]],\"wrapper-id\"]]"
        let value = try PBLiteValue(json: Data(json.utf8))
        let event = try #require(ChannelEvent(ChannelArray(aid: 1, data: value)))
        return ChannelEventMapping.chatEvents(from: event).first
    }

    private func change(_ event: ChatEvent?) -> ThreadChange? {
        guard case let .threadChanged(threadID, conversationID, change)? = event,
              threadID == MessageThread.ID("t-1"), conversationID == Conversation.ID("space/s-1")
        else { return nil }
        return change
    }

    // MARK: - Push 82, the reply count

    /// Field 2 leaves the first message out; `.counted` counts it.
    @Test func pushEightyTwoCountsTheFirstMessage() throws {
        let payload = padded([1: topicID(), 2: "4", 3: "2"], upTo: 3)
        #expect(try change(mapped(body(type: 82, field: 64, payload: payload))) == .counted(
            messages: 5,
            unread: 2
        ))
    }

    /// Field 3 has only been seen as 0, on the owner's own replies (§63.10,
    /// `[Verify]`). A 0 is no claim: stored, it would pin the thread's count
    /// at 0, since history's `nil` keeps it and a read only zeroes it.
    @Test func pushEightyTwoWithZeroUnreadSaysNothingAboutUnread() throws {
        let payload = padded([1: topicID(), 2: "4", 3: "0"], upTo: 3)
        #expect(try change(mapped(body(type: 82, field: 64, payload: payload))) == .counted(
            messages: 5,
            unread: nil
        ))
    }

    @Test func pushEightyTwoInATrailingDictionaryToo() throws {
        let payload = padded([1: topicID(), 2: "7", 3: "2"], upTo: 3)
        let event = try mapped(body(type: 82, field: 64, payload: payload, trailing: true))
        #expect(change(event) == .counted(messages: 8, unread: 2))
    }

    /// The tag is the identity (§12.1.3): the same body under another tag is
    /// not a count.
    @Test func theSameBodyUnderAnotherTagIsUnknown() throws {
        let payload = padded([1: topicID(), 2: "4"], upTo: 2)
        guard case let .unknown(type, _)? = try mapped(body(type: 99, field: 64, payload: payload)) else {
            Issue.record("expected .unknown")
            return
        }
        #expect(type == "googlechat.eventType.99")
    }

    @Test func aCountWithoutATopicIsUnknown() throws {
        let payload = padded([2: "4"], upTo: 2)
        guard case .unknown? = try mapped(body(type: 82, field: 64, payload: payload)) else {
            Issue.record("expected .unknown")
            return
        }
    }

    /// Presence decides: without field 2 the count would read as 0, and
    /// `.counted(messages: 1, …)` would replace the stored count.
    @Test func pushEightyTwoWithoutACountIsUnknown() throws {
        let payload = padded([1: topicID(), 3: "0"], upTo: 3)
        guard case .unknown? = try mapped(body(type: 82, field: 64, payload: payload)) else {
            Issue.record("expected .unknown")
            return
        }
    }

    // MARK: - Push 9, follow

    /// The flag as §63.10 measured it on the wire: `0`/`1`, not `false`/`true`.
    @Test func pushNineMutedIsNotFollowed() throws {
        let muted = padded([1: topicID(), 2: "1"], upTo: 2)
        let unmuted = padded([1: topicID(), 2: "0"], upTo: 2)
        #expect(try change(mapped(body(type: 9, field: 7, payload: muted))) == .followed(false))
        #expect(try change(mapped(body(type: 9, field: 7, payload: unmuted))) == .followed(true))
    }

    /// Presence decides (ruling 4).
    @Test func pushNineWithoutTheFlagIsUnknown() throws {
        guard case .unknown? = try mapped(body(type: 9, field: 7, payload: padded([1: topicID()], upTo: 1)))
        else {
            Issue.record("expected .unknown")
            return
        }
    }

    // MARK: - Push 4, viewed

    @Test func pushFourIsARead() throws {
        let payload = padded([1: topicID(), 2: quoted("1700000000000000")], upTo: 2)
        #expect(try change(mapped(body(type: 4, field: 4, payload: payload)))
            == .read(upTo: Date(timeIntervalSince1970: 1_700_000_000)))
    }

    @Test func pushFourWithoutATimeIsUnknown() throws {
        guard case .unknown? = try mapped(body(type: 4, field: 4, payload: padded([1: topicID()], upTo: 1)))
        else {
            Issue.record("expected .unknown")
            return
        }
    }

    // MARK: - Push 53, a conversation's unread threads

    /// `GroupId {1: SpaceId {1: id}}`.
    private func spaceGroup() -> String {
        padded([1: padded([1: quoted("s-1")], upTo: 1)], upTo: 3)
    }

    @Test func pushFiftyThreeSaysWhetherThreadsAreUnread() throws {
        let payload = padded([1: spaceGroup(), 2: "true", 3: "2"], upTo: 3)
        guard case let .unreadThreadsChanged(conversationID, hasUnread)? =
            try mapped(body(type: 53, field: 46, payload: payload))
        else {
            Issue.record("expected .unreadThreadsChanged")
            return
        }
        #expect(conversationID == Conversation.ID("space/s-1"))
        #expect(hasUnread)
    }

    /// A present `0` says no thread is unread, and clears the flag; a mapping
    /// that read the value instead of its presence would set it and never
    /// clear it.
    @Test func pushFiftyThreeFalseSaysNone() throws {
        let payload = padded([1: spaceGroup(), 2: "0", 3: "0"], upTo: 3)
        #expect(try mapped(body(type: 53, field: 46, payload: payload))
            == .unreadThreadsChanged(conversationID: Conversation.ID("space/s-1"), hasUnread: false))
    }

    /// Presence decides (ruling 4).
    @Test func pushFiftyThreeWithoutTheFlagIsUnknown() throws {
        let payload = padded([1: spaceGroup(), 3: "2"], upTo: 3)
        guard case .unknown? = try mapped(body(type: 53, field: 46, payload: payload)) else {
            Issue.record("expected .unknown")
            return
        }
    }
}
