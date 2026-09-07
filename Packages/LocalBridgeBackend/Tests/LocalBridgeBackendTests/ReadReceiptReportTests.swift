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

    // MARK: - `enabled`

    @Test("disabled account ends the report on that line")
    func disabledAccountEndsTheReport() {
        var set = ReadReceiptSet()
        set.enabled = false
        set.readReceipts = [receipt(userID: "u1", readTimeMicros: 5_000_000)]

        let lines = ReadReceiptReport.lines(
            receiptSet: set,
            topicCount: 3,
            newestCreateTimeUsec: 10_000_000,
            selfUserID: nil
        )

        #expect(lines.contains("  read receipts enabled: false"))
        #expect(lines.contains(where: { $0.contains("DISABLED") }))
        // Nothing past the disabled line describes a receipt - the boolean
        // ends the investigation, per the report's own doc comment.
        #expect(!lines.contains(where: { $0.contains("receipt") && $0.contains("vs newest topic") }))
    }

    @Test("enabled, zero receipts")
    func enabledZeroReceipts() {
        var set = ReadReceiptSet()
        set.enabled = true
        set.readReceipts = []

        let lines = ReadReceiptReport.lines(
            receiptSet: set,
            topicCount: 4,
            newestCreateTimeUsec: 10_000_000,
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
            newestCreateTimeUsec: nil,
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
            newestCreateTimeUsec: 10_000_000,
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
            newestCreateTimeUsec: 10_000_000,
            selfUserID: nil
        )

        #expect(lines.contains(where: { $0.contains("self could not be identified") }))
        #expect(lines.contains(where: { $0.contains("receipt index 0:") }))
    }

    // MARK: - delta arithmetic

    @Test("delta: a receipt behind the newest topic is negative, in seconds")
    func deltaBehindNewestTopicIsNegative() {
        // 1_000_000 usec behind = 1.0 second behind. Written as a literal
        // Double on the right of `==`, never a computed expression - the
        // rule `#expect` needs, since a subexpression like `9 * 86400` is
        // typed alone inside the macro and defaults to `Int`.
        let seconds = ReadReceiptReport.delta(readTimeMicros: 9_000_000, newestCreateTimeUsec: 10_000_000)
        let expected: Double = -1.0
        #expect(seconds == expected)
    }

    @Test("delta: a receipt at or after the newest topic is zero or positive")
    func deltaAtOrAfterNewestTopicIsNonNegative() {
        let atNewest = ReadReceiptReport.delta(readTimeMicros: 10_000_000, newestCreateTimeUsec: 10_000_000)
        let zero: Double = 0
        #expect(atNewest == zero)

        let afterNewest = ReadReceiptReport.delta(
            readTimeMicros: 10_000_001,
            newestCreateTimeUsec: 10_000_000
        )
        let oneMicrosecond = 0.000_001
        #expect(afterNewest == oneMicrosecond)
    }

    @Test("age: newest topic's age in seconds against an injected clock")
    func ageAgainstInjectedClock() {
        let now = Date(timeIntervalSince1970: 5)
        let age = ReadReceiptReport.age(0, now: now)
        let expected = 5.0
        #expect(age == expected)
    }

    // MARK: - conversation selection

    private func conversation(lastActivity: Date?) -> Conversation {
        Conversation(
            id: Conversation.ID(rawValue: "dm:\(UUID().uuidString)"),
            kind: .directMessage,
            lastActivity: lastActivity
        )
    }

    @Test("chooses the conversation with the greatest lastActivity")
    func choosesGreatestLastActivity() {
        let conversations = [
            conversation(lastActivity: Date(timeIntervalSince1970: 100)),
            conversation(lastActivity: Date(timeIntervalSince1970: 300)),
            conversation(lastActivity: Date(timeIntervalSince1970: 200))
        ]
        var lines: [String] = []

        let index = APIProbeReport.chooseConversationIndex(conversations, override: nil, lines: &lines)

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

        let index = APIProbeReport.chooseConversationIndex(conversations, override: nil, lines: &lines)

        #expect(index == 1)
    }

    @Test("an explicit override in range is honoured and reported as explicit")
    func explicitOverrideInRangeIsHonoured() {
        let conversations = [
            conversation(lastActivity: Date(timeIntervalSince1970: 300)),
            conversation(lastActivity: Date(timeIntervalSince1970: 100))
        ]
        var lines: [String] = []

        let index = APIProbeReport.chooseConversationIndex(conversations, override: 1, lines: &lines)

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

        let index = APIProbeReport.chooseConversationIndex(conversations, override: 99, lines: &lines)

        #expect(index == 1)
        #expect(lines.contains(where: { $0.contains("out of range") }))
    }
}
