import Foundation
import GChatBridgeCore

/// Typed `Message` and `Annotation` values for the mentions tests.
///
/// **Still built from the vendored proto's field numbers, not from a
/// capture** - `Message.annotations` (11), `Annotation.type` (1),
/// `start_index` (2), `length` (3), `user_mention_metadata` (5),
/// `UserMentionMetadata.id` (1) and `type` (2). `CLAUDE.md`: "a fixture is not
/// a capture". Their shape now matches what live `list_topics` pages were
/// measured to carry (`findings.md` §40.1, §41.2): `USER_MENTION` (type 6),
/// metadata kind `MENTION` (3), presence bits set, and spans in UTF-16 code
/// units (§41.1). The probe's `mention shapes` section keeps measuring.
///
/// Shared by `MentionMappingTests` and `MentionShapesTests`, which is the
/// same reason `WorldItemFixture` is a support file rather than two private
/// copies.
enum MentionFixture {
    static func spaceGroupID(_ id: String) -> GroupId {
        var group = GroupId()
        var space = SpaceId()
        space.spaceID = id
        group.spaceID = space
        return group
    }

    /// A reply as `Topic.replies` carries one - copied from
    /// `HistoryMappingTests.reply(...)`, plus its annotations.
    static func reply(
        id: String = "m-1",
        groupID: GroupId = spaceGroupID("s-1"),
        topicID: String = "t-1",
        senderID: String = "u-1",
        text: String = "hello",
        createTimeMicros: Int64 = 1_700_000_000_000_000,
        annotations: [GChatBridgeCore.Annotation] = []
    ) -> GChatBridgeCore.Message {
        var topic = TopicId()
        topic.groupID = groupID
        topic.topicID = topicID
        var parent = MessageParentId()
        parent.topicID = topic
        var messageID = MessageId()
        messageID.parentID = parent
        if !id.isEmpty {
            messageID.messageID = id
        }
        var creator = User()
        var senderUserID = UserId()
        senderUserID.id = senderID
        creator.userID = senderUserID

        var message = GChatBridgeCore.Message()
        message.id = messageID
        message.creator = creator
        message.textBody = text
        message.createTime = createTimeMicros
        message.annotations = annotations
        return message
    }

    /// A `USER_MENTION` annotation. Every `nil` stays **absent**, so its
    /// presence bit is clear - which is what a value outside the proto2 enum
    /// also looks like after a typed decode (`CLAUDE.md`, the typed-decode
    /// rule).
    static func mention(
        _ kind: UserMentionMetadata.TypeEnum?,
        user: String?,
        start: Int32?,
        length: Int32?
    ) -> GChatBridgeCore.Annotation {
        var metadata = UserMentionMetadata()
        if let kind {
            metadata.type = kind
        }
        if let user {
            var id = UserId()
            id.id = user
            metadata.id = id
        }
        var annotation = GChatBridgeCore.Annotation()
        annotation.type = .userMention
        annotation.userMentionMetadata = metadata
        if let start {
            annotation.startIndex = start
        }
        if let length {
            annotation.length = length
        }
        return annotation
    }

    /// A `USER_MENTION` whose metadata `type` (field 2) is `raw`, appended as a
    /// varint and then **decoded**, so SwiftProtobuf itself decides where it
    /// lands: outside the closed proto2 enum, the presence bit stays clear and
    /// the bytes go to `unknownFields`. Same reasoning as
    /// `WorldItemFixture.withRawGroupType` - setting `unknownFields` by hand
    /// would test the fixture's idea of that behaviour.
    static func mentionWithRawKind(_ raw: UInt8, start: Int32, length: Int32, user: String? = nil) throws
        -> GChatBridgeCore.Annotation {
        var base = UserMentionMetadata()
        if let user {
            var id = UserId()
            id.id = user
            base.id = id
        }
        var metadataBytes: Data = try base.serializedBytes()
        // Key 0x10 is field 2, wire type 0; `raw` is a one-byte varint (< 128).
        metadataBytes.append(contentsOf: [0x10, raw])
        var annotation = GChatBridgeCore.Annotation()
        annotation.type = .userMention
        annotation.userMentionMetadata = try UserMentionMetadata(serializedBytes: metadataBytes)
        annotation.startIndex = start
        annotation.length = length
        return annotation
    }
}
