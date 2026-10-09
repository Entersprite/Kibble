import ChatKit
import Foundation
import GChatBridgeCore

/// What the `world_items` presence bits and enum values actually say - the
/// counts-only half of the `paginated_world` report.
///
/// Split into its own file for the same `file_length` reason
/// `APIProbeReport+History.swift` already is: adding §37.2's group-type
/// distribution took `APIProbeReport.swift` to 422 lines, past `swiftlint`'s
/// 400-line ceiling.
///
/// Everything here reports **counts only** - never a room name, a member id,
/// a title, or a payload byte. A `paginated_world` response carries real
/// conversations.
extension APIProbeReport {
    /// `threaded` beside **two** unread counts, so the report says which one
    /// it means. `Conversation.hasUnread` is the flag the app actually renders;
    /// `unreadCount > 0` is the one that reads `unread_message_count`, which is
    /// always zero on a real account (`Conversation.unreadCount`'s own doc
    /// comment, `findings.md` §37.8) - so a report that only ever prints the
    /// second number would say "with unread: 0" on an account that plainly has
    /// unread conversations. A small pure `static func` so
    /// `APIProbeReportWorldMappingTests` can pin the wording without a
    /// `paginated_world` round trip.
    static func threadingAndUnreadLine(_ conversations: [Conversation]) -> String {
        "  threaded: \(conversations.count(where: \.isThreaded)), "
            + "with unread (hasUnread): \(conversations.count(where: \.hasUnread)), "
            + "unreadCount > 0: \(conversations.count(where: { $0.unreadCount > 0 }))"
    }

    /// Settles two `[Verify]`s from `WorldMapping.swift` with one live run:
    /// whether `room_name` is ever sent present-and-empty rather than simply
    /// absent, and how often `group_lite` is the only threading information
    /// present (or none of the three is). **Counts only** - never a room
    /// name, a member id, or a payload byte; the presence bits themselves are
    /// the whole report.
    static func appendFieldPresenceCounts(_ items: [WorldItemLite], lines: inout [String]) {
        let roomNameAbsent = items.count(where: { !$0.hasRoomName })
        let roomNamePresentEmpty = items.count(where: { $0.hasRoomName && $0.roomName.isEmpty })
        let roomNamePresentNonEmpty = items.count(where: { $0.hasRoomName && !$0.roomName.isEmpty })
        lines.append(
            "  room_name: absent \(roomNameAbsent), present-empty \(roomNamePresentEmpty), "
                + "present-non-empty \(roomNamePresentNonEmpty)"
        )

        let threadedGroup = items.count(where: \.hasThreadedGroup)
        let flatGroup = items.count(where: \.hasFlatGroup)
        let groupLite = items.count(where: \.hasGroupLite)
        let none = items.count(where: { !$0.hasThreadedGroup && !$0.hasFlatGroup && !$0.hasGroupLite })
        lines.append(
            "  threading fields: threaded_group \(threadedGroup), flat_group \(flatGroup), "
                + "group_lite \(groupLite), none \(none)"
        )

        appendGroupTypeDistribution(items, lines: &lines)
        appendReadStateShape(items, lines: &lines)
    }

    /// The observed distribution of `attribute_checker_group_type` (field 19),
    /// as **counts per raw value**.
    ///
    /// §20.4 recorded that field 19 arrives on every item and never what it
    /// carries, because `ProtoFieldScan` reports sizes and not contents. Now
    /// that `WorldMapping.statedKind(for:)` decides every conversation's kind
    /// from this value, a wrong reading of it would recategorise the whole
    /// sidebar while looking entirely plausible - the family §12.2 and §26
    /// both belong to. This is the cheapest thing that would show it.
    ///
    /// Raw values rather than case names, deliberately: a name is this
    /// build's interpretation, and the number is what the server sent. Counts
    /// only - no identifiers, no titles, no member ids - which is the rule
    /// this file's own doc comment states.
    private static func appendGroupTypeDistribution(
        _ items: [WorldItemLite],
        lines: inout [String]
    ) {
        let absent = items.count(where: { !$0.hasAttributeCheckerGroupType })
        let byValue = Dictionary(
            grouping: items.filter(\.hasAttributeCheckerGroupType),
            by: { $0.attributeCheckerGroupType.rawValue }
        )
        .mapValues(\.count)
        .sorted { $0.key < $1.key }
        .map { "\($0.key): \($0.value)" }
        .joined(separator: ", ")
        lines.append(
            "  attribute_checker_group_type: absent \(absent), "
                + "by value [\(byValue)]"
        )
        appendUnrecognisedGroupTypes(items, absent: absent, lines: &lines)
    }

    /// `WorldItemLite.attribute_checker_group_type`'s field number.
    ///
    /// Named because the value is being read out of `unknownFields`, where
    /// nothing generated can supply it - the whole reason this path exists is
    /// that the typed decode rejected it.
    private static let attributeCheckerGroupTypeField = 19

    /// The raw field-19 values the generated enum could not name.
    ///
    /// The 2026-09-08 run reported `absent 188` of 220 while
    /// `ProtoFieldScan`'s nested item scan showed field 19 present on **every**
    /// item at 1 byte. Both can be true at once only if the value is outside
    /// the generated enum: the proto is `syntax = "proto2"`, so a closed enum
    /// rejects an unrecognised value, leaves the presence bit clear, and keeps
    /// the bytes in `unknownFields`. That was an inference from arithmetic
    /// (205 spaces minus 18 `flatRoom` plus one DM equals the 188), and this
    /// is what measures it instead.
    ///
    /// The count is reported against `absent` deliberately. If every absent
    /// item yields a value, the inference is confirmed and the numbers are the
    /// answer. If **none** does, the inference is wrong and the presence bit
    /// is telling the truth - in which case the nested scan and the mapping
    /// were reading different responses, which is a different bug and needs
    /// knowing rather than assuming.
    private static func appendUnrecognisedGroupTypes(
        _ items: [WorldItemLite],
        absent: Int,
        lines: inout [String]
    ) {
        let values = items
            .filter { !$0.hasAttributeCheckerGroupType }
            .flatMap {
                ProtoFieldScan.varintValues(
                    ofField: attributeCheckerGroupTypeField,
                    in: $0.unknownFields.data
                )
            }
        let byValue = Dictionary(grouping: values, by: { $0 })
            .mapValues(\.count)
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
        lines.append(
            "  attribute_checker_group_type unrecognised: "
                + "\(values.count) of \(absent) absent items carried a value, "
                + "raw [\(byValue)]"
        )
    }

    /// `GroupReadState.last_read_time`'s field number.
    private static let lastReadTimeField = 2

    /// `GroupReadState.unread_message_count`'s field number.
    private static let unreadMessageCountField = 4

    /// `GroupReadState.last_head_message_create_time_usec`'s field number -
    /// printed only. **Read through the typed accessor, never
    /// `unknownFields`:** `67f798c` named the field, so it decodes into
    /// `lastHeadMessageCreateTimeUsec` and never lands in `unknownFields`,
    /// and a scan there reported "present 0" beside a byte scan showing 241
    /// of 244 (`findings.md` §39.1).
    private static let lastHeadMessageTimeField = 29

    /// What is actually inside `read_state` - the field nobody has looked in.
    ///
    /// Every conversation on the real account reports `unreadCount == 0`
    /// (`findings.md` §36.5, confirmed across all 220 in §37.4), and
    /// `WorldMapping` gets that number from
    /// `item.readState.unreadMessageCount`. That is a **proto2 optional read
    /// without its presence bit**, so a field the server never sends returns
    /// 0 and is indistinguishable from "genuinely nothing unread" - the same
    /// mistake §37.4 found in field 19, in a different field.
    ///
    /// So this reports presence separately from value, and adds the
    /// alternative mechanism: purple's `GroupReadState` carries
    /// `last_head_message_create_time_usec` (29) alongside `last_read_time`
    /// (2), and `GroupReadStateUpdatedEvent` carries the same pair. If unread
    /// is **computed** from those rather than delivered as a count, that is
    /// the strictly-greater-than timestamp comparison §36 already established
    /// for *publishing* read state, read in the other direction.
    ///
    /// **No timestamps are printed.** Both are large varints, which
    /// `ProtoFieldScan.varintValues(ofField:in:)`'s own doc comment warns not
    /// to log blindly. What is reported is the **derived** answer - how many
    /// conversations have a newest message later than their read position -
    /// which is the number that decides the question and carries nothing
    /// about when anybody spoke.
    private static func appendReadStateShape(_ items: [WorldItemLite], lines: inout [String]) {
        let present = items.filter(\.hasReadState)
        lines.append("  read_state: present \(present.count) of \(items.count)")
        guard !present.isEmpty else { return }
        let shape = readStateShape(of: present)

        let inventory = shape.innerCounts.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
        lines.append("  read_state inner fields (items carrying each) [\(inventory)]")

        let unreadDistribution = shape.unreadValues.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
        lines.append(
            "  unread_message_count (\(unreadMessageCountField)): "
                + "present \(shape.unreadPresent) of \(present.count), "
                + "values [\(unreadDistribution)]"
        )
        lines.append(
            "  last_read_time (\(lastReadTimeField)): present \(shape.lastReadPresent), "
                + "last_head_message_create_time_usec (\(lastHeadMessageTimeField)): "
                + "present \(shape.headTimePresent)"
        )
        lines.append(
            "  newest message not covered by read position (>, findings 42): "
                + "\(shape.notCoveredByRead) of \(present.count)"
        )
        // Session 29's read-position diagnosis: the same pair, as a signed
        // microsecond histogram rather than a single threshold count - see
        // `APIProbeReport+ReadPositions.swift`.
        lines.append(contentsOf: readPositionDeltaLines(readPositionDeltas(items)))
    }

    /// What one pass over `read_state` measured. Split from the reporting
    /// above only because the combined function crossed `swiftlint`'s
    /// 50-line `function_body_length`.
    private struct ReadStateShape {
        var innerCounts: [Int: Int] = [:]
        var unreadValues: [UInt64: Int] = [:]
        var unreadPresent = 0
        var lastReadPresent = 0
        var headTimePresent = 0
        var notCoveredByRead = 0
    }

    private static func readStateShape(of items: [WorldItemLite]) -> ReadStateShape {
        var shape = ReadStateShape()
        for item in items {
            let state = item.readState
            let bytes = (try? state.serializedData()) ?? Data()
            for field in Set(ProtoFieldScan.fields(in: bytes).fields.map(\.number)) {
                shape.innerCounts[field, default: 0] += 1
            }
            if state.hasUnreadMessageCount {
                shape.unreadPresent += 1
                shape.unreadValues[UInt64(max(0, state.unreadMessageCount)), default: 0] += 1
            }
            if state.hasLastReadTime {
                shape.lastReadPresent += 1
            }
            // The same typed reads `WorldMapping.hasUnread` makes (§39.1).
            let headTime = state.hasLastHeadMessageCreateTimeUsec
                ? state.lastHeadMessageCreateTimeUsec
                : nil
            if headTime != nil {
                shape.headTimePresent += 1
            }
            // `>`, matching `WorldMapping.hasUnread`: a position equal to the
            // newest message covers it (`findings.md` §42). The histogram's
            // `equal` bucket still counts those separately.
            if let headTime, state.hasLastReadTime, headTime > state.lastReadTime {
                shape.notCoveredByRead += 1
            }
        }
        return shape
    }

    /// §20.4's `[Verify]`: the ladder's own scan is top-level only, so which
    /// `WorldItemLite` fields are actually populated has never been observed.
    /// Field numbers, wire types and byte counts - the same vocabulary the
    /// top-level report already uses, never a value.
    /// Moved here from `APIProbeReport.swift` for `file_length`, unchanged.
    static func appendNestedItemShapes(_ results: [WorldRungResult], lines: inout [String]) {
        lines.append("world_item nested shape (field numbers inside each field-4 entry):")
        var any = false
        for result in results {
            guard !result.worldItemFields.isEmpty else { continue }
            any = true
            lines.append("  \(result.label):")
            for (index, fields) in result.worldItemFields.enumerated() {
                let rendered = fields
                    .map { "\($0.number):w\($0.wireType)=\($0.byteCount)B" }
                    .joined(separator: " ")
                lines.append("    item \(index + 1): \(rendered.isEmpty ? "(none)" : rendered)")
            }
        }
        if !any {
            lines.append("  no world_items in any rung")
        }
    }
}
