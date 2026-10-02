import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `ReadReceiptReport`'s decoding and delta arithmetic, and
/// `APIProbeReport.chooseConversationIndex`'s conversation selection - both
/// pure, so both are tested here against invented values with no network and
/// no account, the same posture `TopicsRequestLadderTests` already takes for
/// the ladder itself.
@Suite("ReadReceiptReport")
struct ReadReceiptReportTests {
    private func receipt(userID: String, readTimeMicros: Int64) -> ReadReceipt {
        var user = User()
        var id = UserId()
        id.id = userID
        user.userID = id
        var receipt = ReadReceipt()
        receipt.user = user
        receipt.readTimeMicros = readTimeMicros
        return receipt
    }

    /// A reference whose `sortTime` and `newestReplyCreateTime` equal
    /// `createTimeUsec` unless overridden - most tests care only about the
    /// receipt deltas, so the topic's own timing fields default to "in
    /// agreement with the reference" rather than forcing every call site to
    /// spell out three numbers to get one.
    private func reference(
        createTimeUsec: Int64,
        sortTime: Int64? = nil,
        newestReplyCreateTime: Int64? = nil
    ) -> ReadReceiptReport.NewestTopicReference {
        ReadReceiptReport.NewestTopicReference(
            createTimeUsec: createTimeUsec,
            sortTime: sortTime ?? createTimeUsec,
            newestReplyCreateTime: newestReplyCreateTime ?? createTimeUsec
        )
    }

    // MARK: - `enabled`

    @Test("disabled for this conversation ends the report on that line")
    func disabledConversationEndsTheReport() {
        var set = ReadReceiptSet()
        set.enabled = false
        set.readReceipts = [receipt(userID: "u1", readTimeMicros: 5_000_000)]

        let lines = ReadReceiptReport.lines(
            receiptSet: set,
            topicCount: 3,
            newestTopicReference: reference(createTimeUsec: 10_000_000),
            selfUserID: nil
        )

        #expect(lines.contains("  read receipts enabled: false"))
        // One response is one conversation, never the account (§39.2).
        #expect(lines.contains(where: { $0.contains("DISABLED for this conversation") }))
        #expect(!lines.contains(where: { $0.contains("account") }))
        // Nothing past the disabled line describes a receipt - the boolean
        // ends the investigation, per the report's own doc comment.
        #expect(!lines.contains(where: { $0.contains("receipt") && $0.contains("vs reference") }))
    }

    /// §39.2: in proto2 an absent optional bool reads as `false`, so printing
    /// `enabled` without `hasEnabled` turned "the response did not say" into
    /// "disabled". Absent is reported as absent, and ends nothing.
    @Test("an absent enabled is reported as absent, not false")
    func absentEnabledIsReportedAsAbsent() {
        let lines = ReadReceiptReport.lines(
            receiptSet: ReadReceiptSet(),
            topicCount: 1,
            newestTopicReference: reference(createTimeUsec: 10_000_000),
            selfUserID: nil
        )

        #expect(lines.contains("  read receipts enabled: absent"))
        #expect(!lines.contains(where: { $0.contains("DISABLED") }))
        #expect(lines.contains("  receipts: 0"))
    }

    @Test("enabled, zero receipts")
    func enabledZeroReceipts() {
        var set = ReadReceiptSet()
        set.enabled = true
        set.readReceipts = []

        let lines = ReadReceiptReport.lines(
            receiptSet: set,
            topicCount: 4,
            newestTopicReference: reference(createTimeUsec: 10_000_000),
            selfUserID: nil
        )

        #expect(lines.contains("  read receipts enabled: true"))
        #expect(lines.contains("  receipts: 0"))
        #expect(!lines.contains(where: { $0.contains("could not be identified") }))
    }

    @Test("no topics in the response - cannot compute an age or a delta")
    func noTopicsInResponse() {
        var set = ReadReceiptSet()
        set.enabled = true

        let lines = ReadReceiptReport.lines(
            receiptSet: set,
            topicCount: 0,
            newestTopicReference: nil,
            selfUserID: nil
        )

        #expect(lines.contains(where: { $0.contains("cannot compute an age or a delta") }))
    }

    // MARK: - self/other resolution

    @Test("self identified: matching id labelled self, non-matching labelled other")
    func selfIdentifiedLabelsCorrectly() {
        var set = ReadReceiptSet()
        set.enabled = true
        set.readReceipts = [
            receipt(userID: "self-id", readTimeMicros: 10_000_000),
            receipt(userID: "other-id", readTimeMicros: 3_000_000)
        ]

        let lines = ReadReceiptReport.lines(
            receiptSet: set,
            topicCount: 2,
            newestTopicReference: reference(createTimeUsec: 10_000_000),
            selfUserID: "self-id"
        )

        #expect(lines.contains(where: { $0.contains("receipt self:") }))
        #expect(lines.contains(where: { $0.contains("receipt other:") }))
        #expect(!lines.contains(where: { $0.contains("could not be identified") }))
    }

    @Test("self not identified: receipts reported by index, and the report says so")
    func selfNotIdentifiedReportsByIndex() {
        var set = ReadReceiptSet()
        set.enabled = true
        set.readReceipts = [receipt(userID: "someone", readTimeMicros: 10_000_000)]

        let lines = ReadReceiptReport.lines(
            receiptSet: set,
            topicCount: 1,
            newestTopicReference: reference(createTimeUsec: 10_000_000),
            selfUserID: nil
        )

        #expect(lines.contains(where: { $0.contains("self could not be identified") }))
        #expect(lines.contains(where: { $0.contains("receipt index 0:") }))
    }

    // MARK: - delta arithmetic (microseconds, exact integers)

    @Test("deltaMicros: a receipt one microsecond short of the reference is -1")
    func deltaMicrosOneMicrosecondShort() {
        // The exact scenario three-decimal seconds could not distinguish
        // from "four hundred microseconds short" - both used to print
        // `-0.000s`. Written as a computed literal rather than an
        // expression on the right of `==`, since a subexpression like
        // `10_000_000 - 1` is type-checked alone inside `#expect` and
        // defaults to `Int` rather than taking its type from the left side.
        let micros = ReadReceiptReport.deltaMicros(readTimeMicros: 9_999_999, referenceUsec: 10_000_000)
        let expected: Int64 = -1
        #expect(micros == expected)
    }

    @Test("deltaMicros: a receipt exactly at the reference is 0")
    func deltaMicrosExactlyAtReference() {
        let micros = ReadReceiptReport.deltaMicros(readTimeMicros: 10_000_000, referenceUsec: 10_000_000)
        let expected: Int64 = 0
        #expect(micros == expected)
    }

    @Test("deltaMicros: a receipt past the reference is positive")
    func deltaMicrosPastReference() {
        let micros = ReadReceiptReport.deltaMicros(readTimeMicros: 10_000_001, referenceUsec: 10_000_000)
        let expected: Int64 = 1
        #expect(micros == expected)
    }

    // MARK: - the newest topic's own timing fields

    @Test("topic timing lines report sort_time, create_time_usec and newest reply create_time as signed µs")
    func topicTimingLinesReportAllThreeDeltas() {
        var set = ReadReceiptSet()
        set.enabled = true
        set.readReceipts = [receipt(userID: "someone", readTimeMicros: 10_000_000)]

        let lines = ReadReceiptReport.lines(
            receiptSet: set,
            topicCount: 1,
            newestTopicReference: reference(
                createTimeUsec: 10_000_000,
                sortTime: 10_000_050,
                newestReplyCreateTime: 9_999_880
            ),
            selfUserID: nil
        )

        #expect(lines.contains(where: { $0.contains("newest topic sort_time: +50µs") }))
        #expect(lines.contains(where: { $0.contains("newest topic create_time_usec: +0µs") }))
        #expect(lines.contains(where: { $0.contains("newest reply create_time: -120µs") }))
    }

    @Test("newest reply create_time earlier than the topic's create_time_usec reports negative")
    func newestReplyEarlierThanTopicCreateTimeUsec() {
        // The hypothesis findings.md §36 raised: if the server stamps the
        // topic marginally later than the message inside it, the reply's
        // create_time sits *before* the topic's create_time_usec by a fixed
        // sub-millisecond amount, insensitive to message age. This asserts
        // the arithmetic that would surface exactly that on a live run.
        var set = ReadReceiptSet()
        set.enabled = true

        let lines = ReadReceiptReport.lines(
            receiptSet: set,
            topicCount: 1,
            newestTopicReference: reference(
                createTimeUsec: 10_000_000,
                newestReplyCreateTime: 9_999_700
            ),
            selfUserID: nil
        )

        #expect(lines.contains(where: { $0.contains("newest reply create_time: -300µs") }))
    }

    @Test("age: newest topic's age in seconds against an injected clock")
    func ageAgainstInjectedClock() {
        let now = Date(timeIntervalSince1970: 5)
        let age = ReadReceiptReport.age(0, now: now)
        let expected = 5.0
        #expect(age == expected)
    }

    // MARK: - conversation selection

    private func conversation(lastActivity: Date?, kind: Conversation.Kind = .directMessage) -> Conversation {
        Conversation(
            id: Conversation.ID(rawValue: "dm:\(UUID().uuidString)"),
            kind: kind,
            lastActivity: lastActivity
        )
    }

    /// A busy space - one an app posts into every few minutes - outruns any
    /// DM on recency, so the newest message in a DM someone just staged is
    /// never what "most recently active" picks (`findings.md` §52).
    @Test("dm picks the most recently active direct message over a newer space")
    func dmPicksTheNewestDirectMessage() {
        let conversations = [
            conversation(lastActivity: Date(timeIntervalSince1970: 100)),
            conversation(lastActivity: Date(timeIntervalSince1970: 900), kind: .space),
            conversation(lastActivity: Date(timeIntervalSince1970: 200)),
            conversation(lastActivity: Date(timeIntervalSince1970: 50))
        ]
        var lines: [String] = []

        let index = APIProbeReport.chooseConversationIndex(
            conversations, choice: .mostRecentDirectMessage, lines: &lines
        )

        #expect(index == 2)
        #expect(lines.contains(where: { $0.contains("most recently active direct message") }))
    }

    @Test("dm with no direct message falls back to most recently active, with a note")
    func dmWithoutADirectMessageFallsBack() {
        let conversations = [
            conversation(lastActivity: Date(timeIntervalSince1970: 100), kind: .space),
            conversation(lastActivity: Date(timeIntervalSince1970: 300), kind: .space)
        ]
        var lines: [String] = []

        let index = APIProbeReport.chooseConversationIndex(
            conversations, choice: .mostRecentDirectMessage, lines: &lines
        )

        #expect(index == 1)
        #expect(lines.contains(where: { $0.contains("no direct message") }))
    }

    @Test(arguments: [
        ("dm", ProbeConversation.mostRecentDirectMessage),
        ("DM", .mostRecentDirectMessage),
        ("3", .index(3)),
        ("", .mostRecent),
        ("space", .mostRecent),
        ("-1", .mostRecent)
    ])
    func theArgumentIsParsed(_ argument: String, _ expected: ProbeConversation) {
        #expect(ProbeConversation(argument: argument) == expected)
    }

    @Test("chooses the conversation with the greatest lastActivity")
    func choosesGreatestLastActivity() {
        let conversations = [
            conversation(lastActivity: Date(timeIntervalSince1970: 100)),
            conversation(lastActivity: Date(timeIntervalSince1970: 300)),
            conversation(lastActivity: Date(timeIntervalSince1970: 200))
        ]
        var lines: [String] = []

        let index = APIProbeReport.chooseConversationIndex(conversations, choice: .mostRecent, lines: &lines)

        #expect(index == 1)
        #expect(lines.contains(where: { $0.contains("most recently active") }))
    }

    @Test("nil lastActivity sorts lowest, never chosen over a timestamped conversation")
    func nilLastActivitySortsLowest() {
        let conversations = [
            conversation(lastActivity: nil),
            conversation(lastActivity: Date(timeIntervalSince1970: 1))
        ]
        var lines: [String] = []

        let index = APIProbeReport.chooseConversationIndex(conversations, choice: .mostRecent, lines: &lines)

        #expect(index == 1)
    }

    @Test("an explicit override in range is honoured and reported as explicit")
    func explicitOverrideInRangeIsHonoured() {
        let conversations = [
            conversation(lastActivity: Date(timeIntervalSince1970: 300)),
            conversation(lastActivity: Date(timeIntervalSince1970: 100))
        ]
        var lines: [String] = []

        let index = APIProbeReport.chooseConversationIndex(conversations, choice: .index(1), lines: &lines)

        #expect(index == 1)
        #expect(lines.contains(where: { $0.contains("explicit --probe-conversation") }))
    }

    @Test("an out-of-range override falls back to most recently active, with a note")
    func outOfRangeOverrideFallsBack() {
        let conversations = [
            conversation(lastActivity: Date(timeIntervalSince1970: 100)),
            conversation(lastActivity: Date(timeIntervalSince1970: 300))
        ]
        var lines: [String] = []

        let index = APIProbeReport.chooseConversationIndex(conversations, choice: .index(99), lines: &lines)

        #expect(index == 1)
        #expect(lines.contains(where: { $0.contains("out of range") }))
    }

    // MARK: - the probed conversation's kind

    /// §39.2: one run's receipts may be a DM's and another's a space's, so the
    /// report names the probed conversation's kind - ChatKit's own wire token,
    /// which identifies nobody.
    @Test("the kind line prints ChatKit's wire token", arguments: [
        (Conversation.Kind.space, "space"),
        (.directMessage, "directMessage"),
        (.meetChat, "meetChat"),
        (.unknown("10"), "10")
    ])
    func kindLinePrintsTheWireToken(kind: Conversation.Kind, token: String) {
        #expect(APIProbeReport.conversationKindLine(kind) == "  probed conversation kind: \(token)")
    }
}
