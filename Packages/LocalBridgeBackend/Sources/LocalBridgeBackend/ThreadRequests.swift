import Foundation
import GChatBridgeCore
import SwiftProtobuf

/// The thread calls Chat on the web makes and no vendored proto names (`findings.md` §64), as bytes
/// for `ProtoAPIClient.callRaw`, and the readers for what comes back. Every layout here was read
/// out of the web client's code and is `[Verify]` until a probe run sends it.
enum ThreadRequests {
    static let metadataMethod = "get_user_topic_metadata"
    /// The capital T is the web client's own spelling (§64.1).
    static let muteMethod = "mark_Topic_mute_state"
    /// Tried only when the web client's spelling is refused.
    static let lowercaseMuteMethod = "mark_topic_mute_state"
    static let markReadMethod = "mark_topic_readstate"
    static let unreadMethod = "set_topic_unread_timestamp"
    /// Home's Threads chip (§64.6).
    static let followedPageSize: UInt64 = 30
    static let followedFetchOptions: [UInt64] = [4, 2, 5, 6, 7, 3]

    /// `{1: TopicId}`, with no request header (§64.1).
    static func metadata(_ topic: TopicId) -> Data {
        var writer = ProbeProtoWriter()
        writer.bytes(1, bytes(of: topic))
        return writer.data
    }

    /// `{1: TopicId, 2: bool mute, 100: RequestHeader}`. Unfollow is `mute: true` (§64.1).
    static func muteState(
        _ topic: TopicId, mute: Bool, header: RequestHeader = APIRequestHeader.make()
    ) -> Data {
        var writer = ProbeProtoWriter()
        writer.bytes(1, bytes(of: topic))
        writer.bool(2, mute)
        writer.bytes(100, bytes(of: header))
        return writer.data
    }

    /// `{1: TopicId, 2: int64 µs, 100: RequestHeader}`, the shape of both `mark_topic_readstate`
    /// (the newest message's time) and `set_topic_unread_timestamp` (a message's time minus 1 µs,
    /// or 0 to clear) (§64.2, §64.3).
    static func topicTime(
        _ topic: TopicId, micros: Int64, header: RequestHeader = APIRequestHeader.make()
    ) -> Data {
        var writer = ProbeProtoWriter()
        writer.bytes(1, bytes(of: topic))
        writer.int64(2, micros)
        writer.bytes(100, bytes(of: header))
        return writer.data
    }

    /// `paginated_world` as Home's Threads chip sends it (§64.6): followed threads, no
    /// conversations, newest first, one reply each. Plus `fetch_from_user_spaces` (5), which Home's
    /// request had no need of and §64.7's empty answer lacked: Kibble's own world load sends it.
    static func followedThreads(header: RequestHeader = APIRequestHeader.make()) -> Data {
        var writer = ProbeProtoWriter()
        writer.bytes(1, bytes(of: header))
        writer.message(2) { section in
            section.varint(1, followedPageSize)
            section.message(4) { $0.bool(17, true) }
            section.message(9) { filter in
                filter.message(2) { $0.varint(1, 1) }
                filter.bool(4, true)
            }
            section.message(10) { option in
                option.message(1) { replies in
                    replies.varint(1, 1)
                    replies.bool(2, true)
                }
                option.message(2) { $0.bool(1, true) }
            }
            section.message(11) { $0.varint(1, 1) }
            section.message(15) { $0.varint(1, 1) }
        }
        for option in followedFetchOptions {
            writer.varint(4, option)
        }
        writer.bool(5, true)
        return writer.data
    }

    static func bytes(of message: some SwiftProtobuf.Message) -> Data {
        (try? message.serializedBytes()) ?? Data()
    }

    // MARK: - Reading the answers

    /// The best decoding of a raw answer, by the rule `TopicsRequestLadder` uses.
    static func body(_ raw: RawAPIResponse) -> Data {
        let candidates = APIResponseBody.candidates(raw.body)
        let best = candidates.first { !ProtoFieldScan.fields(in: $0.bytes).truncated } ?? candidates.first
        return best?.bytes ?? Data()
    }

    /// `get_user_topic_metadata`'s field 2, "is muted"; `nil` when absent.
    static func muted(in body: Data) -> Bool? {
        ProtoFieldScan.varintValues(ofField: 2, in: body).first.map { $0 != 0 }
    }

    /// A value read back against the one sent, in microseconds. Never the value itself.
    static func readBack(_ value: Int64?, sent: Int64) -> String {
        guard let value else { return "absent" }
        if value == sent {
            return "equal"
        }
        return value < sent ? "\(sent - value) µs earlier" : "\(value - sent) µs later"
    }

    /// Topic field 11 as bytes, unknown fields included.
    static func readState(of topic: GChatBridgeCore.Topic) -> Data {
        topic.hasTopicReadState ? bytes(of: topic.topicReadState) : Data()
    }

    /// `TopicReadState` 13, the reply summary (§64.4).
    static func summary(of topic: GChatBridgeCore.Topic) -> Data? {
        ProtoFieldScan.payloads(ofField: 13, in: readState(of: topic)).first
    }

    /// `TopicReadState` 2, `last_read_time` (the vendored proto's `thread_created_usec`).
    static func lastRead(of topic: GChatBridgeCore.Topic) -> Int64? {
        ProtoFieldScan.varintValues(ofField: 2, in: readState(of: topic)).first.map { Int64(bitPattern: $0) }
    }

    /// `TopicReadState` 14, `mark_topic_as_unread_time`, which neither proto names.
    static func markedUnread(of topic: GChatBridgeCore.Topic) -> Int64? {
        ProtoFieldScan.varintValues(ofField: 14, in: readState(of: topic)).first.map { Int64(bitPattern: $0) }
    }

    /// `TopicReadState` 4, purple's `unread_message_count`, undecoded until §64.9 [Verify].
    static func unreadCount(of topic: GChatBridgeCore.Topic) -> Int64? {
        ProtoFieldScan.varintValues(ofField: 4, in: readState(of: topic)).first.map { Int64(bitPattern: $0) }
    }

    /// `TopicReadState` 5, purple's `read_message_count`.
    static func readCount(of topic: GChatBridgeCore.Topic) -> Int64? {
        ProtoFieldScan.varintValues(ofField: 5, in: readState(of: topic)).first.map { Int64(bitPattern: $0) }
    }

    /// `TopicReadState` 10, purple's `total_message_count`, absent on every topic of §64.7's run.
    static func totalCount(of topic: GChatBridgeCore.Topic) -> Int64? {
        ProtoFieldScan.varintValues(ofField: 10, in: readState(of: topic)).first.map { Int64(bitPattern: $0) }
    }

    /// `TopicReadState` 11's labels, purple's `TopicLabelId`: each one's type (its field 1), -1 when
    /// it has none. Its field 2, a string key, is never read.
    static func labelTypes(of topic: GChatBridgeCore.Topic) -> [Int] {
        ProtoFieldScan.payloads(ofField: 11, in: readState(of: topic)).map { label in
            ProtoFieldScan.varintValues(ofField: 1, in: label).first.map { Int(clamping: $0) } ?? -1
        }
    }

    /// The summary's field 2, unread replies.
    static func unreadReplies(of topic: GChatBridgeCore.Topic) -> UInt64? {
        summary(of: topic).flatMap { ProtoFieldScan.varintValues(ofField: 2, in: $0).first }
    }

    /// Field numbers with how often each occurs, `none` when empty.
    static func fieldTally(_ body: Data) -> String {
        var counts: [Int: Int] = [:]
        for field in ProtoFieldScan.fields(in: body).fields {
            counts[field.number, default: 0] += 1
        }
        guard !counts.isEmpty else { return "none" }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
    }
}
