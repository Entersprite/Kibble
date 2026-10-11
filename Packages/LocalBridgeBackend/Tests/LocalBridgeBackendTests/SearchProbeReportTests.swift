import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The probe prints shapes, never content (CLAUDE.md, "mask by parsing").
struct SearchProbeReportTests {
    /// Lowercase on purpose: a masker that only hid uppercase would pass a
    /// test whose secret was uppercase (session 36).
    @Test func aShapeHidesEveryString() {
        let value: [Any] = ["secretword", 7, NSNull(), ["inner name", [1, 2]], ["k": "v"]]
        let shape = SearchProbeReport.shape(of: value, depth: 4)
        #expect(!shape.contains("secretword"))
        #expect(!shape.contains("inner name"))
        #expect(shape == #"[s10, 7, null, [s10, [1, 2]], {k: s1}]"#)
    }

    @Test func aShapeStopsAtItsDepth() {
        #expect(SearchProbeReport.shape(of: [[["deep"]]], depth: 1) == "[<list 1>]")
    }

    @Test func aLargeNumberIsReportedByItsDigits() {
        #expect(SearchProbeReport.shape(of: [1_790_000_000_000], depth: 2) == "[n13d]")
    }
}

// MARK: - Task 3: the anchor stage (findings.md §65.9)

/// `Microseconds.from(_:)`/`Microseconds.date(_:)`'s round trip, pinned for a
/// 16-digit value - the precision `AnchorPick.anchorTimeUsec` depends on
/// (`task-3-brief.md`: "an in-memory µs → Date → µs round trip is exact",
/// CLAUDE.md's §36 note).
struct MicrosecondsRoundTripTests {
    @Test func a16DigitMicrosecondValueRoundTripsExactly() {
        let micros: Int64 = 1_700_000_123_456_789
        #expect(Microseconds.from(Microseconds.date(micros)) == micros)
    }
}

/// The anchor stage's pure parts: picking the hit, summarizing a response
/// against its anchor, and the verdict line - `SearchProbeReport+Anchor.swift`.
/// None of this touches the network; `appendAnchorStage` itself is exercised
/// only by the owner's live run (`task-3-brief.md` step 3).
struct SearchProbeReportAnchorTests {
    // MARK: - Picking the hit

    private static func hit(
        id: String,
        conversationID: String,
        secondsAgo: TimeInterval,
        isReply: Bool = false
    ) -> ChatKit.Message {
        ChatKit.Message(
            id: ChatKit.Message.ID(id),
            conversationID: Conversation.ID(conversationID),
            threadID: MessageThread.ID(id),
            sender: Member.ID("u-1"),
            text: "x",
            createdAt: Date().addingTimeInterval(-secondsAgo),
            isReply: isReply
        )
    }

    @Test func oldestHitPicksTheMinimumCreatedAt() {
        let newer = Self.hit(id: "m-new", conversationID: "space/sp-1", secondsAgo: 10)
        let older = Self.hit(id: "m-old", conversationID: "space/sp-1", secondsAgo: 1000)
        #expect(SearchProbeReport.oldestHit(from: [newer, older])?.id.rawValue == "m-old")
    }

    @Test func oldestHitOfAnEmptyListIsNil() {
        #expect(SearchProbeReport.oldestHit(from: []) == nil)
    }

    @Test func pickAnchorUsesTheOldestDecodedHitsOwnConversationAndTime() throws {
        let only = Self.hit(id: "m-1", conversationID: "space/sp-9", secondsAgo: 500, isReply: true)
        let pick = try #require(SearchProbeReport.pickAnchor(candidateHits: [only], firstRawHit0: nil))
        #expect(ChannelEventMapping.conversationID(pick.group)?.rawValue == "space/sp-9")
        #expect(pick.hitMessageID == "m-1")
        #expect(pick.hitCreatedAt == only.createdAt)
        #expect(pick.hitIsReply == true)
        #expect(pick.anchorTimeUsec == Microseconds.from(only.createdAt))
        #expect(pick.source.contains("oldest of 1 decoded hit"))
    }

    /// The raw hit shape §65.8 found: `[inner, 2]`, group reference at index
    /// 2 (field 3) of `inner`. Built by hand rather than reusing
    /// `SearchHitMappingTests`'s private fixture builder, which this task is
    /// explicitly barred from editing.
    private static func rawHit0(group: PBLiteValue) throws -> Any {
        var fields = [PBLiteValue](repeating: .null, count: 18)
        fields[2] = group
        let value: PBLiteValue = [.array(fields), 2]
        return try JSONSerialization.jsonObject(with: value.jsonData())
    }

    @Test func pickAnchorFallsBackToHit0sConversationWhenNoHitDecodes() throws {
        let raw = try Self.rawHit0(group: ["space/sp-1", "sp-1", 2])
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let pick = try #require(SearchProbeReport.pickAnchor(candidateHits: [], firstRawHit0: raw, now: now))
        #expect(ChannelEventMapping.conversationID(pick.group)?.rawValue == "space/sp-1")
        #expect(pick.hitMessageID == nil)
        #expect(pick.hitCreatedAt == nil)
        #expect(pick.hitIsReply == nil)
        #expect(pick.source.contains("fallback"))
        let thirtyDaysUsec: Int64 = 30 * 24 * 60 * 60 * 1_000_000
        #expect(pick.anchorTimeUsec == Microseconds.from(now) - thirtyDaysUsec)
    }

    @Test func pickAnchorIsNilWhenNothingCanBeRead() {
        #expect(SearchProbeReport.pickAnchor(candidateHits: [], firstRawHit0: nil) == nil)
    }

    @Test func pickAnchorIsNilWhenHit0sGroupReferenceIsUnrecognised() throws {
        let raw = try Self.rawHit0(group: ["other/sp-1", "sp-1", 2])
        #expect(SearchProbeReport.pickAnchor(candidateHits: [], firstRawHit0: raw) == nil)
    }

    @Test func fallbackGroupIDReadsADMReference() throws {
        let raw = try Self.rawHit0(group: ["dm/dm-1", "dm-1", 2])
        let group = try #require(SearchProbeReport.fallbackGroupID(fromRawHit0: raw))
        #expect(ChannelEventMapping.conversationID(group)?.rawValue == "dm/dm-1")
    }

    /// Fix round 1, review finding 2: a two-element space reference (no
    /// trailing `2`) must be refused, the same rule
    /// `SearchHitMapping.groupReference(_:)` already enforces for its own
    /// caller. This is what caught `fallbackGroupID` silently dropping that
    /// check when it duplicated the match instead of calling the shared
    /// function.
    @Test func fallbackGroupIDRefusesASpaceReferenceMissingTheTrailingTwo() throws {
        let raw = try Self.rawHit0(group: ["space/sp-1", "sp-1"])
        #expect(SearchProbeReport.fallbackGroupID(fromRawHit0: raw) == nil)
    }

    @Test func fallbackGroupIDRefusesASpaceReferenceWhoseThirdElementIsNotTwo() throws {
        let raw = try Self.rawHit0(group: ["space/sp-1", "sp-1", 5])
        #expect(SearchProbeReport.fallbackGroupID(fromRawHit0: raw) == nil)
    }

    // MARK: - Topic order

    @Test func topicOrderAscending() {
        #expect(SearchProbeReport.anchorTopicOrder([1, 2, 3]) == "ascending")
    }

    @Test func topicOrderDescending() {
        #expect(SearchProbeReport.anchorTopicOrder([3, 2, 1]) == "descending")
    }

    @Test func topicOrderMixed() {
        #expect(SearchProbeReport.anchorTopicOrder([1, 3, 2]) == "mixed")
    }

    @Test func topicOrderWithFewerThanTwoTopicsIsNotApplicable() {
        #expect(SearchProbeReport.anchorTopicOrder([]) == "n/a (0 topic)")
        #expect(SearchProbeReport.anchorTopicOrder([1]) == "n/a (1 topic)")
    }

    // MARK: - The decisive reading

    @Test func readingDoesNotPageWhenContainsLastTopicIsTrue() {
        #expect(SearchProbeReport.anchorReading(
            containsFirstTopic: false, containsLastTopic: true, offsetsSeconds: [100]
        ).contains("does not page"))
    }

    @Test func readingPagesInclusiveWhenEveryTimeIsAtOrBeforeTheAnchor() {
        #expect(SearchProbeReport.anchorReading(
            containsFirstTopic: false, containsLastTopic: false, offsetsSeconds: [-10, 0, -1]
        ).contains("pages, inclusive"))
    }

    @Test func readingIsInconclusiveWithNoMessages() {
        #expect(SearchProbeReport.anchorReading(
            containsFirstTopic: false, containsLastTopic: false, offsetsSeconds: []
        ).contains("inconclusive"))
    }

    @Test func readingIsInconclusiveWhenATimeIsAfterTheAnchorButContainsLastTopicIsFalse() {
        #expect(SearchProbeReport.anchorReading(
            containsFirstTopic: false, containsLastTopic: false, offsetsSeconds: [-10, 5]
        ).contains("inconclusive"))
    }

    /// Fix round 1, review finding 1: a small conversation that comes back
    /// whole (`contains_first_topic` and `contains_last_topic` both true) is
    /// not evidence either way - both readings predict exactly that - so it
    /// must not read as "does not page" even though `containsLastTopic`
    /// alone is true. This is the test that was red against the old
    /// two-parameter `anchorReading` (see the fix report).
    @Test func readingIsInconclusiveWhenTheWholeConversationCameBackInOnePage() {
        let reading = SearchProbeReport.anchorReading(
            containsFirstTopic: true, containsLastTopic: true, offsetsSeconds: [-10, 5]
        )
        #expect(reading.contains("inconclusive"))
        #expect(!reading.contains("does not page"))
    }

    /// Guard check: with only `containsLastTopic` true (not `containsFirstTopic`
    /// too), the page reached the newest topic without reaching the oldest -
    /// real asymmetric evidence, not the whole-conversation case, so this
    /// must still read "does not page".
    @Test func readingStillDoesNotPageWhenOnlyContainsLastTopicIsTrue() {
        #expect(SearchProbeReport.anchorReading(
            containsFirstTopic: false, containsLastTopic: true, offsetsSeconds: [100]
        ).contains("does not page"))
    }

    // MARK: - Summarizing a response

    private static func message(id: String, createTimeUsec: Int64, text: String = "") -> GChatBridgeCore
        .Message {
        var message = GChatBridgeCore.Message()
        message.id.messageID = id
        message.createTime = createTimeUsec
        message.textBody = text
        return message
    }

    private static func topic(createTimeUsec: Int64, replies: [GChatBridgeCore.Message]) -> Topic {
        var topic = Topic()
        topic.createTimeUsec = createTimeUsec
        topic.replies = replies
        return topic
    }

    @Test func summarizeCountsTopicsMessagesAndOffsets() {
        let anchor: Int64 = 1_000_000_000_000_000
        var response = ListTopicsResponse()
        response.topics = [
            Self.topic(createTimeUsec: 100, replies: [
                Self.message(id: "a", createTimeUsec: anchor - 2_000_000), // -2s
                Self.message(id: "b", createTimeUsec: anchor) // 0s
            ]),
            Self.topic(createTimeUsec: 200, replies: [
                Self.message(id: "c", createTimeUsec: anchor + 3_000_000) // +3s
            ])
        ]
        response.containsFirstTopic = true
        response.containsLastTopic = false

        let summary = SearchProbeReport.summarize(
            response: response,
            anchorTimeUsec: anchor,
            hitMessageID: "b"
        )
        #expect(summary.topicCount == 2)
        #expect(summary.messageCount == 3)
        #expect(summary.containsFirstTopic == true)
        #expect(summary.containsLastTopic == false)
        #expect(summary.minOffsetSeconds == -2)
        #expect(summary.maxOffsetSeconds == 3)
        #expect(summary.olderCount == 1)
        #expect(summary.equalCount == 1)
        #expect(summary.newerCount == 1)
        #expect(summary.hitIncluded == true)
        #expect(summary.topicOrder == "ascending")
    }

    @Test func summarizeReportsHitNotIncluded() {
        var response = ListTopicsResponse()
        response.topics = [Self.topic(createTimeUsec: 1, replies: [Self.message(id: "a", createTimeUsec: 1)])]
        let summary = SearchProbeReport.summarize(response: response, anchorTimeUsec: 1, hitMessageID: "z")
        #expect(summary.hitIncluded == false)
    }

    @Test func summarizeWithNoHitMessageIDReportsHitIncludedAsNil() {
        var response = ListTopicsResponse()
        response.topics = [Self.topic(createTimeUsec: 1, replies: [Self.message(id: "a", createTimeUsec: 1)])]
        let summary = SearchProbeReport.summarize(response: response, anchorTimeUsec: 1, hitMessageID: nil)
        #expect(summary.hitIncluded == nil)
    }

    @Test func summarizeOfAnEmptyResponseHasNilMinAndMax() {
        let summary = SearchProbeReport.summarize(
            response: ListTopicsResponse(),
            anchorTimeUsec: 1,
            hitMessageID: nil
        )
        #expect(summary.minOffsetSeconds == nil)
        #expect(summary.maxOffsetSeconds == nil)
        #expect(summary.topicOrder == "n/a (0 topic)")
    }

    // MARK: - Rendering

    @Test func configLineNamesTheStagesKnobs() {
        var request = ListTopicsRequest()
        request.pageSizeForTopics = 32
        request.pageSizeForReplies = 50
        let line = SearchProbeReport.anchorConfigLine(request: request)
        #expect(line.contains("offsets 1/0/-1 µs"))
        #expect(line.contains("sort_option 2"))
        #expect(line.contains("page_size_for_topics 32"))
        #expect(line.contains("page_size_for_replies 50"))
    }

    @Test func labelsNameEachOffset() {
        #expect(SearchProbeReport.label(forAnchorOffset: 1) == "anchor +1µs")
        #expect(SearchProbeReport.label(forAnchorOffset: 0) == "anchor exact")
        #expect(SearchProbeReport.label(forAnchorOffset: -1) == "anchor -1µs")
    }

    /// The leak test: a sentinel the shape-based masker elsewhere in this
    /// probe would not catch by construction, because `anchorReportLines`
    /// never touches a message's id or text at all - it only ever reads
    /// `AnchorResponseSummary`'s numbers and booleans. Lowercase, per
    /// CLAUDE.md's "a leak test's sentinel must be one the masker would
    /// otherwise let through".
    @Test func anchorReportLinesNeverLeakAMessageIDOrText() {
        let sentinelID = "leakmessageidvalue"
        let sentinelText = "leaktextvalue"
        var response = ListTopicsResponse()
        var message = Self.message(id: sentinelID, createTimeUsec: 1, text: sentinelText)
        message.id.messageID = sentinelID
        response.topics = [Self.topic(createTimeUsec: 1, replies: [message])]
        response.containsLastTopic = true

        // hitMessageID equal to the sentinel, so the "yes" branch (the one
        // that reads the id) is the one under test.
        let summary = SearchProbeReport.summarize(
            response: response,
            anchorTimeUsec: 1,
            hitMessageID: sentinelID
        )
        let rendered = SearchProbeReport.anchorReportLines(label: "anchor exact", summary: summary).joined()
        #expect(!rendered.contains(sentinelID))
        #expect(!rendered.contains(sentinelText))
        #expect(rendered.contains("yes"))
    }
}
