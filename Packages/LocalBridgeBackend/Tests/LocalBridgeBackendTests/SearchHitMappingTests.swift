import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// A search hit (`SBNmJb`, `findings.md` §65.8) becoming a `ChatKit.Message`.
///
/// **These fixtures are synthetic**: every value is invented, but the
/// *shape* - which index holds which field, when a field moves into the
/// trailing object - is read off the committed redacted capture
/// (`Packages/GChatBridgeCore/Tests/GChatBridgeCoreTests/Fixtures/batchexecute
/// /sbnmjb-answer.txt`), not guessed (`CLAUDE.md`: "a fixture is not a
/// capture").
struct SearchHitMappingTests {
    // MARK: - Building a hit in the shape §65.8 found

    private static let spaceGroup: PBLiteValue = ["space/sp-1", "sp-1", 2]
    private static let dmGroup: PBLiteValue = ["dm/dm-1", "dm-1", 2]

    /// A hit, `[inner, 2]`, with `inner`'s fields at the indices §65.8 found:
    /// group (index 2, field 3), sender (index 4, field 5), text (index 5,
    /// field 6), annotations (index 8, field 9), create time (index 11, field
    /// 12), the id triplet `[msgId, null, [topicId, null, groupRef]]` (index
    /// 17, field 18). `replyFlag` lands positionally (index 57, field 58)
    /// unless `replyFlagInTrailing` says to append it as the trailing
    /// object's `"58"` instead - the placement §65.8 found on 2 of 302 hits.
    private static func hit(
        messageID: String? = "m-1",
        topicID: String? = "m-1",
        group: PBLiteValue? = spaceGroup,
        senderID: String? = "u-1",
        text: String = "hello",
        createdAtMicros: String? = "1700000000000000",
        annotations: [PBLiteValue] = [],
        replyFlag: Bool? = nil,
        replyFlagInTrailing: Bool = false
    ) -> PBLiteValue {
        var fields = [PBLiteValue](repeating: .null, count: 18)
        fields[2] = group ?? .null
        fields[4] = [senderID.map(PBLiteValue.string) ?? .null]
        fields[5] = .string(text)
        fields[8] = .array(annotations)
        fields[11] = createdAtMicros.map(PBLiteValue.string) ?? .null
        fields[17] = [
            messageID.map(PBLiteValue.string) ?? .null,
            .null,
            [topicID.map(PBLiteValue.string) ?? .null, .null, group ?? .null]
        ]
        var trailing: [String: PBLiteValue] = [:]
        if let replyFlag {
            if replyFlagInTrailing {
                trailing["58"] = .bool(replyFlag)
            } else {
                while fields.count < 58 {
                    fields.append(.null)
                }
                fields[57] = .bool(replyFlag)
            }
        }
        var array = fields
        if !trailing.isEmpty {
            array.append(.object(trailing))
        }
        return [.array(array), 2]
    }

    /// `PBLiteValue` round-tripped through JSON, the shape `page(from:)`
    /// actually receives (`JSONSerialization`'s `Any`), rather than a `Codable`
    /// value handed in directly.
    private static func any(_ value: PBLiteValue) throws -> Any {
        try JSONSerialization.jsonObject(with: value.jsonData())
    }

    // MARK: - A root hit: every field reused from history's own mapping

    @Test func aRootHitMapsEveryField() throws {
        let mapped = try #require(SearchHitMapping.message(from: Self.hit(
            messageID: "m-1", topicID: "m-1", senderID: "u-1", text: "hello",
            createdAtMicros: "1700000000000000"
        )))
        #expect(mapped.id.rawValue == "m-1")
        #expect(mapped.conversationID.rawValue == "space/sp-1")
        #expect(mapped.threadID.rawValue == "m-1")
        #expect(mapped.sender.rawValue == "u-1")
        #expect(mapped.text == "hello")
        #expect(mapped.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(mapped.isReply == false)
    }

    // MARK: - A reply hit

    @Test func aReplyHitIsAReplyOfItsRootsThreadID() throws {
        let mapped = try #require(SearchHitMapping.message(from: Self.hit(
            messageID: "m-2", topicID: "m-1", replyFlag: true
        )))
        #expect(mapped.threadID.rawValue == "m-1")
        #expect(mapped.isReply == true)
    }

    @Test func aReplyFlagInTheTrailingObjectStillMarksItAReply() throws {
        let mapped = try #require(SearchHitMapping.message(from: Self.hit(
            messageID: "m-2", topicID: "m-1", replyFlag: true, replyFlagInTrailing: true
        )))
        #expect(mapped.isReply == true)
    }

    /// Without field 58 at all, `ThreadMapping.isReply`'s id-comparison
    /// fallback still gets this right - §65.8 measured the two rules
    /// agreeing on every hit the capture saw.
    @Test func aReplyHitWithNoField58StillReadsAsAReplyByItsOwnIDs() throws {
        let mapped = try #require(SearchHitMapping.message(from: Self.hit(messageID: "m-2", topicID: "m-1")))
        #expect(mapped.isReply == true)
    }

    /// Guard check: this is the one case the id-comparison fallback cannot
    /// get right, so it is the test that actually exercises the code reading
    /// field 58 rather than the fallback it is layered over. Deleting the
    /// `if case let .bool(isReply)? = fields.field(58)` guard in
    /// `SearchHitMapping.message(from:)` turns this from green to red: the
    /// fallback alone would call this a first message, since its id equals
    /// its own topic id.
    @Test func fieldFiftyEightOverridesTheIDFallbackWhenTheyDisagree() throws {
        let mapped = try #require(SearchHitMapping.message(from: Self.hit(
            messageID: "m-1", topicID: "m-1", replyFlag: true
        )))
        #expect(mapped.isReply == true)
    }

    // MARK: - Mentions, links and uploads, mapped exactly like history

    @Test func aMentionIsMappedLikeHistory() throws {
        var metadata = UserMentionMetadata()
        metadata.type = .mention
        var userID = UserId()
        userID.id = "u-2"
        metadata.id = userID
        var annotation = GChatBridgeCore.Annotation()
        annotation.type = .userMention
        annotation.userMentionMetadata = metadata
        annotation.startIndex = 0
        annotation.length = 5
        let raw = try PBLiteEncoder.encode(annotation)

        let mapped = try #require(SearchHitMapping.message(from: Self.hit(annotations: [raw])))
        #expect(mapped.mentions == [ChatKit.Mention(target: .user(Member.ID("u-2")), start: 0, length: 5)])
    }

    @Test func aLinkIsMappedLikeHistory() throws {
        var metadata = UrlMetadata()
        metadata.url.url = "https://example.com/doc"
        metadata.title = "Example"
        var annotation = GChatBridgeCore.Annotation()
        annotation.type = .url
        annotation.urlMetadata = metadata
        annotation.startIndex = 0
        annotation.length = 4
        let raw = try PBLiteEncoder.encode(annotation)

        let mapped = try #require(SearchHitMapping.message(from: Self.hit(text: "read", annotations: [raw])))
        #expect(try mapped.links.map(\.url) == [#require(URL(string: "https://example.com/doc"))])
    }

    @Test func anUploadIsMappedLikeHistory() throws {
        var metadata = UploadMetadata()
        metadata.attachmentToken = "token-1"
        metadata.contentName = "photo.png"
        metadata.contentType = "image/png"
        var annotation = GChatBridgeCore.Annotation()
        annotation.type = .uploadMetadata
        annotation.uploadMetadata = metadata
        let raw = try PBLiteEncoder.encode(annotation)

        let mapped = try #require(SearchHitMapping.message(from: Self.hit(annotations: [raw])))
        #expect(mapped.attachments.map(\.id) == ["token-1"])
    }

    // MARK: - A search highlight, stripped before it reaches `PBLiteDecoder`

    /// Not tested through `message(from:)`: a `FORMAT_DATA` annotation (a
    /// highlight included) never becomes a mention, a link or an attachment
    /// either way, so stripping it has no effect any of those three could
    /// show. `mappedAnnotations(_:)` is called directly instead, the same
    /// reason `ChannelEventMapping.mentions(_:)` and its siblings are not
    /// `private`.
    @Test func aSearchHighlightIsStrippedFromTheAnnotationList() {
        let highlight: PBLiteValue = [8, 0, 3, nil, nil, nil, nil, [13]]
        #expect(SearchHitMapping.mappedAnnotations([highlight]).isEmpty)
    }

    /// Guard check: deleting the `format_metadata == [13]` half of
    /// `isSearchHighlight` (leaving only `type == FORMAT_DATA`) turns this
    /// red - a `BULLETED_LIST` span (format 10, the extra spans §65.8 found
    /// on 15 hits) would then be stripped too.
    @Test func anOrdinaryFormatAnnotationIsNotStripped() {
        let bulletedList: PBLiteValue = [8, 0, 3, nil, nil, nil, nil, [10]]
        let mapped = SearchHitMapping.mappedAnnotations([bulletedList])
        #expect(mapped.count == 1)
        #expect(mapped.first?.type == .formatData)
    }

    /// Guard check: deleting the `type == FORMAT_DATA` half (leaving only
    /// `format_metadata == [13]`) turns this red - annotation *type* 13 is
    /// the real, unrelated `UPLOAD_METADATA` (§65.8's named collision), and
    /// `anUploadIsMappedLikeHistory` above would also fail, since a real
    /// upload's own top-level type is literally 13.
    @Test func onlyAFormatDataAnnotationCanBeAHighlight() {
        let oddlyShaped: PBLiteValue = [1, 0, 3, nil, nil, nil, nil, [13]]
        #expect(SearchHitMapping.mappedAnnotations([oddlyShaped]).count == 1)
    }

    // MARK: - The group reference

    @Test func aDMFormReferenceMapsToADMConversation() throws {
        let mapped = try #require(SearchHitMapping.message(from: Self.hit(group: Self.dmGroup)))
        #expect(mapped.conversationID.rawValue == "dm/dm-1")
    }

    @Test func anUnknownReferenceShapeIsDropped() {
        let unknown: PBLiteValue = ["other/sp-1", "sp-1", 2]
        #expect(SearchHitMapping.message(from: Self.hit(group: unknown)) == nil)
    }

    // MARK: - Dropped, for a missing id or an invalid time

    @Test func aHitMissingAnIDIsDropped() {
        #expect(SearchHitMapping.message(from: Self.hit(messageID: nil)) == nil)
    }

    @Test func aHitMissingATimeIsDropped() {
        #expect(SearchHitMapping.message(from: Self.hit(createdAtMicros: nil)) == nil)
    }

    @Test func aHitWithAnInvalidTimeIsDropped() {
        #expect(SearchHitMapping.message(from: Self.hit(createdAtMicros: "not-a-number")) == nil)
    }

    // MARK: - A page: its hits, the next token, and how many were dropped

    @Test func pageReturnsItsHitsTheNextTokenAndHowManyWereDropped() throws {
        let good = try Self.any(Self.hit(messageID: "m-1"))
        let bad = try Self.any(Self.hit(messageID: nil))
        var answer: [Any] = Array(repeating: NSNull(), count: 9) + [[good, bad]]
        answer[0] = "token-1"

        let page = SearchHitMapping.page(from: answer)
        #expect(page.hits.map(\.id.rawValue) == ["m-1"])
        #expect(page.dropped == 1)
        #expect(page.next == "token-1")
    }

    @Test func pageWithNoTokenHasANilNext() throws {
        let good = try Self.any(Self.hit(messageID: "m-1"))
        var answer: [Any] = Array(repeating: NSNull(), count: 9) + [[good]]
        answer[0] = ""
        #expect(SearchHitMapping.page(from: answer).next == nil)
    }

    @Test func pageWithFewerThanTenAnswerSlotsHasNoHits() {
        let page = SearchHitMapping.page(from: ["token-1"])
        #expect(page.hits.isEmpty)
        #expect(page.dropped == 0)
        #expect(page.next == "token-1")
    }

    // MARK: - The committed redacted capture

    /// `findings.md` §65.8's own evidence came from this capture, and its
    /// syntax - not its values, which are shape tokens - is what every
    /// synthetic fixture above is checked against. This only asserts that
    /// parsing the real shape never traps; a redacted capture's `create_time`
    /// is the literal text `"str(16)"`, not 16 digits, so every hit here is
    /// expected to be dropped on the time check, not mapped.
    @Test func theCommittedRedactedCaptureParsesWithoutTrapping() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LocalBridgeBackendTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // LocalBridgeBackend
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent()
        let fixture = repositoryRoot.appendingPathComponent(
            "Packages/GChatBridgeCore/Tests/GChatBridgeCoreTests/Fixtures/batchexecute/sbnmjb-answer.txt"
        )
        let answers = try BatchExecute.answers(in: Data(contentsOf: fixture))
        let search = try #require(answers.first { $0.rpc == "SBNmJb" })
        let payload = try #require(search.payload)
        let inner = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [Any])

        let page = SearchHitMapping.page(from: inner)
        #expect(page.hits.count + page.dropped == 2)
    }
}
