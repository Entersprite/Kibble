import ChatKit
import Foundation
import GChatBridgeCore

/// What `segmented_membership_counts` (field 30) carries, and whether
/// `WorldMapping.memberCount(for:)`'s rule matches it - `findings.md` §43.
///
/// The rule is an inference from purple's proto: sum the JOINED segments
/// across member types. Two things settle it, and both are printed:
///
/// - **The raw segment shapes**, read by walking each segment's own bytes,
///   not through the typed accessors. `member_type` and `membership_state`
///   are proto2 closed enums, so a value outside the vendored set clears
///   its presence bit and would read as absent (`CLAUDE.md`, the typed
///   decode rule).
/// - **The derived count beside the listed members**, per kind. A DM lists
///   both people, so a rule that is right gives `derived - listed = 0` on
///   every one. A group chat's list may be truncated, so there it may only
///   be `>= 0`. A space lists nobody, so there the count is all there is.
///
/// **Counts only**, per this report's contract. Member counts are small
/// integers about how many people, never who.
extension APIProbeReport {
    /// `SegmentedMembershipCount`'s field numbers, for the byte walk.
    private static let segmentCountField = 1
    private static let segmentTypeField = 2
    private static let segmentStateField = 3

    static func membershipCountLines(
        _ items: [WorldItemLite],
        conversations: [Conversation]
    ) -> [String] {
        let present = items.filter(\.hasSegmentedMembershipCounts)
        var lines = [
            "membership counts (field 30, segmented_membership_counts, findings 43):",
            "  present: \(present.count) of \(items.count)"
        ]
        guard !present.isEmpty else { return lines }

        let perItem = Dictionary(grouping: present, by: \.segmentedMembershipCounts.value.count)
            .mapValues(\.count)
        lines.append("  segments per item [\(histogram(perItem))]")
        lines.append("  segment shapes, raw bytes (type/state: segments) [\(segmentShapes(present))]")
        lines.append(
            "  memberCount derived: \(conversations.count(where: { $0.memberCount != nil })) "
                + "of \(conversations.count)"
        )
        lines.append("  derived - listed members, by kind:")
        let byKind = Dictionary(grouping: conversations) { "\($0.kind)" }
        for kind in byKind.keys.sorted() {
            let ofKind = byKind[kind] ?? []
            let deltas = Dictionary(grouping: ofKind.compactMap { conversation in
                conversation.memberCount.map { $0 - conversation.members.count }
            }) { $0 }.mapValues(\.count)
            // Numeric order, signed, so `+10` sorts after `+2`.
            let buckets = deltas.sorted { $0.key < $1.key }
                .map { "\($0.key > 0 ? "+" : "")\($0.key): \($0.value)" }
                .joined(separator: ", ")
            let unknown = ofKind.count(where: { $0.memberCount == nil })
            lines.append("    \(kind): [\(buckets)], no count: \(unknown)")
        }
        return lines
    }

    /// `type/state` per segment, each read from the segment's own bytes, `-`
    /// where the field is absent.
    private static func segmentShapes(_ items: [WorldItemLite]) -> String {
        var shapes: [String: Int] = [:]
        for segment in items.flatMap(\.segmentedMembershipCounts.value) {
            let bytes = (try? segment.serializedData()) ?? Data()
            let type = ProtoFieldScan.varintValues(ofField: segmentTypeField, in: bytes).first
            let state = ProtoFieldScan.varintValues(ofField: segmentStateField, in: bytes).first
            let hasCount = !ProtoFieldScan.varintValues(ofField: segmentCountField, in: bytes).isEmpty
            let shape = "\(type.map(String.init) ?? "-")/\(state.map(String.init) ?? "-")"
                + (hasCount ? "" : " (no count)")
            shapes[shape, default: 0] += 1
        }
        return histogram(shapes)
    }

    private static func histogram(_ counts: [some Comparable & CustomStringConvertible: Int]) -> String {
        counts.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
    }
}
