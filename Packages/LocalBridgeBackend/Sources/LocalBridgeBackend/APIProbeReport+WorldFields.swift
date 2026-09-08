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
}
