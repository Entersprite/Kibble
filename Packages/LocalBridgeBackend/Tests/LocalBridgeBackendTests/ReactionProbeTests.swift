import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The probe's reaction section: counts only, and nothing that could carry an
/// id, an emoji, a shortcode or a URL.
struct ReactionProbeTests {
    private func message(
        id: String,
        topic: String = "t-1",
        reactions: [GChatBridgeCore.Reaction]
    ) -> GChatBridgeCore.Message {
        var message = GChatBridgeCore.Message()
        message.id.messageID = id
        message.id.parentID.topicID.topicID = topic
        message.id.parentID.topicID.groupID.spaceID.spaceID = "s-1"
        message.reactions = reactions
        return message
    }

    private func unicode(
        _ text: String, count: Int32, mine: Bool = false, createTimestamp: Int64? = nil
    ) -> GChatBridgeCore.Reaction {
        var reaction = GChatBridgeCore.Reaction()
        reaction.emoji.unicode = text
        reaction.count = count
        reaction.currentUserParticipated = mine
        if let createTimestamp {
            reaction.createTimestamp = createTimestamp
        }
        return reaction
    }

    /// The sentinel sits in every value a custom-emoji fetch might need
    /// (`uuid`, `shortcode`, `blob_id`, `read_token`, and - when `url` is
    /// given - `ephemeral_url`), so the leak test below exercises all five at
    /// once (`CLAUDE.md`: pick the secret from inside the masker's own
    /// exception).
    private func custom(url: String?, count: Int32) -> GChatBridgeCore.Reaction {
        var reaction = GChatBridgeCore.Reaction()
        reaction.emoji.customEmoji.uuid = "secret-uuid"
        reaction.emoji.customEmoji.shortcode = ":secretshortcode:"
        reaction.emoji.customEmoji.blobID = "secret-blob-id"
        reaction.emoji.customEmoji.readToken = "secret-read-token"
        if let url {
            reaction.emoji.customEmoji.ephemeralURL = url
        }
        reaction.count = count
        return reaction
    }

    /// Neither a unicode string nor a custom emoji - an `Emoji` with nothing
    /// set, the shape `shapes.neither` exists to count.
    private func neither(count: Int32) -> GChatBridgeCore.Reaction {
        var reaction = GChatBridgeCore.Reaction()
        reaction.count = count
        return reaction
    }

    @Test func itCountsKindsAndTalliesCounts() {
        let shapes = APIProbeReport.reactionShapes([
            message(
                id: "m-1",
                reactions: [
                    unicode("👍", count: 2, mine: true),
                    custom(url: "https://x.invalid/e", count: 1),
                    neither(count: 1)
                ]
            ),
            message(id: "m-2", reactions: []),
            message(id: "m-3", reactions: [unicode("🎉", count: 1, createTimestamp: 1_700_000_000)])
        ])
        #expect(shapes.messages == 3)
        #expect(shapes.withReactions == 2)
        #expect(shapes.reactions == 4)
        #expect(shapes.unicode == 2)
        #expect(shapes.custom == 1)
        #expect(shapes.customWithURL == 1)
        #expect(shapes.neither == 1)
        #expect(shapes.includesMe == 1)
        #expect(shapes.withCreateTimestamp == 1)
        #expect(shapes.countTally == [1: 3, 2: 1])
        // Two unicode emoji (field 1) and one custom (field 2); `neither`'s
        // empty `Emoji` serializes to zero bytes and contributes to neither.
        #expect(shapes.emojiFields == [1: 2, 2: 1])
        #expect(shapes.firstReacted?.messageID == "m-1")
        #expect(shapes.firstCustomURL == "https://x.invalid/e")
    }

    /// The leak test's sentinels are lowercase and inside every value a line
    /// could print (`CLAUDE.md`: pick the secret from inside the masker's
    /// exception).
    @Test func noLineCarriesAnIDAnEmojiAShortcodeOrAURL() {
        let shapes = APIProbeReport.reactionShapes([
            message(
                id: "secretmessageid",
                topic: "secrettopicid",
                reactions: [
                    unicode("👍", count: 2),
                    custom(url: "https://secrethost.invalid/secretpath", count: 1)
                ]
            )
        ])
        let text = APIProbeReport.reactionShapesLines(shapes).joined(separator: "\n")
        #expect(!text.contains("secret"))
        #expect(!text.contains("👍"))
    }

    /// The image fetch's lines go through the attachment probe's own
    /// reporting (`renderHost`), which keeps an unknown host's registrable
    /// domain - its last two labels - **on purpose**, so a report can say
    /// which service answered (`findings.md` §52 diagnosed hosts exactly this
    /// way). What must never print is everything that domain does not need:
    /// any subdomain label below it, a path segment, or a query name. So the
    /// sentinel sits only in those - `secretlabel` (a subdomain label kept out
    /// of the registrable domain), the path segments and the query name - and
    /// never in the registrable domain itself (`example.invalid`).
    @Test func theImageFetchLinesCarryNoAddress() {
        let fetched = FetchedAttachment(
            body: Data("PNG".utf8), contentType: "image/png",
            hops: [AttachmentHop(
                host: "secretlabel.lh3.example.invalid", status: 200, carriedCredentials: false,
                pathSegments: ["secretsegment", "secrettoken"], queryNames: ["secretname"], location: nil
            )]
        )
        let text = APIProbeReport.attachmentFetchLines(label: "ephemeral_url", outcome: .success(fetched))
            .joined(separator: "\n")
        #expect(!text.contains("secret"))
    }

    /// `CLAUDE.md`: "believe the walk" - a field neither this repo's vendored
    /// proto nor purple's names still has to show up, because the next field
    /// Google adds to `Emoji` will not be in either until someone notices it
    /// on the wire. Built by hand rather than through the generated setters,
    /// since no setter exists for a field the message does not declare: field
    /// 9, wire type 2 (length-delimited), a 3-byte payload. Decoding through
    /// `Emoji(serializedBytes:)` is what exercises the real path - SwiftProtobuf
    /// keeps an unrecognised field in `unknownFields` and re-emits it on the
    /// next `serializedBytes()`, which is what `reactionShapes` then walks.
    @Test func anEmojiWithAnUnnamedFieldStillShowsInTheWalk() throws {
        let fieldNineLengthDelimited = Data([0x4A, 0x03, 0x01, 0x02, 0x03])
        let emoji = try GChatBridgeCore.Emoji(serializedBytes: fieldNineLengthDelimited)
        var reaction = GChatBridgeCore.Reaction()
        reaction.emoji = emoji
        reaction.count = 1
        let shapes = APIProbeReport.reactionShapes([message(id: "m-1", reactions: [reaction])])
        #expect(shapes.emojiFields[9] == 1)
    }

    /// The `Reaction`-level sibling of the test above: a reactor-identity
    /// field would sit here, one level above `Emoji`, which is exactly the
    /// byte walk `emojiFields` cannot reach - hence `reactionFields` as its
    /// own tally. Field 10, wire type 0 (varint), value 5.
    @Test func aReactionWithAnUnnamedFieldShowsInTheReactionWalk() throws {
        let fieldTenVarint = Data([0x50, 0x05])
        let reaction = try GChatBridgeCore.Reaction(serializedBytes: fieldTenVarint)
        let shapes = APIProbeReport.reactionShapes([message(id: "m-1", reactions: [reaction])])
        #expect(shapes.reactionFields[10] == 1)
    }

    // MARK: - Custom emoji: what a fetch for its image needs

    /// A custom emoji carrying everything a fetch might use: the byte walk
    /// sees every field it set, `content_type` and `state` land in their own
    /// tallies, and the three candidate fetch inputs are counted by length,
    /// never by value.
    @Test func itWalksCustomEmojiFieldsContentTypeStateAndInputLengths() {
        var reaction = GChatBridgeCore.Reaction()
        reaction.emoji.customEmoji.uuid = "secret-uuid"
        reaction.emoji.customEmoji.shortcode = ":secretshortcode:"
        reaction.emoji.customEmoji.blobID = "secret-blob-identifier"
        reaction.emoji.customEmoji.readToken = "secret-read-token-value"
        reaction.emoji.customEmoji.ephemeralURL = "https://secrethost.invalid/secretpath"
        reaction.emoji.customEmoji.contentType = "image/png"
        reaction.emoji.customEmoji.state = .emojiEnabled
        reaction.count = 1
        let shapes = APIProbeReport.reactionShapes([message(id: "m-1", reactions: [reaction])])
        // Fields present on the wire: 1 uuid, 3 shortcode, 4 state, 7 blob_id,
        // 9 read_token, 11 ephemeral_url, 12 content_type.
        #expect(shapes.customFields == [1: 1, 3: 1, 4: 1, 7: 1, 9: 1, 11: 1, 12: 1])
        #expect(shapes.customContentTypes == ["image/png": 1])
        #expect(shapes.customStates == [GChatBridgeCore.EmojiState.emojiEnabled.rawValue: 1])
        let blobLength = "secret-blob-identifier".utf8.count
        let tokenLength = "secret-read-token-value".utf8.count
        let urlLength = "https://secrethost.invalid/secretpath".utf8.count
        #expect(shapes.customBlobIDLengths == [blobLength: 1])
        #expect(shapes.customReadTokenLengths == [tokenLength: 1])
        #expect(shapes.customEphemeralURLLengths == [urlLength: 1])
    }

    /// `CLAUDE.md`: "believe the walk" - a field neither vendored proto names
    /// still has to show up inside `CustomEmoji` too, the same way it already
    /// does for `Emoji` and `Reaction`. Field 20, wire type 0 (varint), value
    /// 5: tag byte is `(20 << 3) | 0 = 160`, which needs two varint bytes
    /// since it exceeds 127.
    @Test func aCustomEmojiWithAnUnnamedFieldStillShowsInTheWalk() throws {
        let fieldTwentyVarint = Data([0xA0, 0x01, 0x05])
        let customEmoji = try GChatBridgeCore.CustomEmoji(serializedBytes: fieldTwentyVarint)
        var reaction = GChatBridgeCore.Reaction()
        reaction.emoji.customEmoji = customEmoji
        reaction.count = 1
        let shapes = APIProbeReport.reactionShapes([message(id: "m-1", reactions: [reaction])])
        #expect(shapes.customFields[20] == 1)
    }

    /// `EmojiState` is a closed proto2 enum, so a raw value it does not name
    /// clears `hasState` and the typed decode would read as "absent" - the
    /// same trap `MentionShapesTests` pins for `AnnotationType` and
    /// `UserMentionMetadata.TypeEnum`. Field 4, wire type 0, value 9 - one
    /// past `emojiDeleted` (4), outside the enum's 0...4 range.
    @Test func aRawStateOutsideTheEnumShowsViaTheUnknownFieldsVarintPath() throws {
        let fieldFourValueNine = Data([0x20, 0x09])
        let customEmoji = try GChatBridgeCore.CustomEmoji(serializedBytes: fieldFourValueNine)
        #expect(!customEmoji.hasState) // positive control on the fixture
        var reaction = GChatBridgeCore.Reaction()
        reaction.emoji.customEmoji = customEmoji
        reaction.count = 1
        let shapes = APIProbeReport.reactionShapes([message(id: "m-1", reactions: [reaction])])
        #expect(shapes.customStates == [9: 1])
    }

    @Test func aMessageWithNoReactionsAnywhereSaysSo() {
        let lines = APIProbeReport.reactionShapesLines(APIProbeReport.reactionShapes([message(
            id: "m",
            reactions: []
        )]))
        #expect(lines.contains { $0.contains("messages with reactions: 0/1") })
    }
}
