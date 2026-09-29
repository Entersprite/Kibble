import ChatKit
import Foundation
import GChatBridgeCore

/// What `get_user_presence` answers - the first live evidence for
/// `PresenceMapping`, and for the `[Verify]`s the presence poll rests on:
/// that the call works at all, whether one request can carry every DM
/// partner, which of the two DND fields a poll fills, and whether any
/// presence value falls outside the vendored enum.
///
/// The same request `LocalBridgeBackend.pollPresence` sends, over the people
/// the world load's `get_members` named (`presenceTargets`) - the app's first
/// run. The app's later runs also carry every sender met since, so they are
/// larger than this; a limit that only bites there shows up as poll failures,
/// not here. **Counts only**, per this report's contract:
/// never an id, a name, or a custom status's text - only whether one is
/// present.
extension APIProbeReport {
    /// `UserPresence.presence`'s and `DndSettings.dnd_state`'s field numbers,
    /// for the byte walk.
    private static let presenceField = 2
    private static let dndStateField = 1
    private static let topLevelDndField = 3

    static func appendPresenceSummary(
        members: [ChatKit.Member],
        client: ProtoAPIClient,
        lines: inout [String]
    ) async {
        lines.append("presence summary (get_user_presence):")
        let ids = LocalBridgeBackend.presenceTargets(from: members)
        lines.append("  people asked about: \(ids.count)")
        guard !ids.isEmpty else { return }
        let response: GetUserPresenceResponse
        do {
            response = try await client.call(.getUserPresence, LocalBridgeBackend.getUserPresenceRequest(ids))
        } catch {
            lines.append("  FAILED: \(safeDescription(of: error))")
            return
        }
        lines.append(contentsOf: presenceLines(response, asked: ids))
    }

    static func presenceLines(_ response: GetUserPresenceResponse, asked: [ChatKit.Member.ID]) -> [String] {
        let entries = response.userPresences
        let askedIDs = Set(asked.map(\.rawValue))
        let answeredIDs = Set(entries.map(\.userID.id))
        let answeredAsked = answeredIDs.intersection(askedIDs).count
        var lines = ["  entries returned: \(entries.count), of them asked about: \(answeredAsked)"]
        lines.append("  presence, typed or raw [\(presenceHistogram(entries.map(presenceShape)))]")
        lines.append("  dnd_state (field 3) [\(presenceHistogram(entries.map(topLevelDndShape)))]")
        lines
            .append(
                "  user_status.dnd_settings.dnd_state [\(presenceHistogram(entries.map(statusDndShape)))]"
            )
        lines.append(
            "  with active_until: \(entries.count(where: \.hasActiveUntil)), "
                + "with user_status: \(entries.count(where: \.hasUserStatus)), "
                + "with custom status: \(entries.count(where: { $0.userStatus.hasCustomStatus }))"
        )
        let mapped = PresenceMapping.map(response)
        lines.append("  mapped [\(presenceHistogram(mapped.values.map { "\($0)" }))]")
        return lines
    }

    /// The typed name, or `raw=N` read from the bytes when the presence bit is
    /// clear but the field is on the wire (`CLAUDE.md`, the typed decode rule),
    /// or `-` when it is genuinely absent.
    private static func presenceShape(_ entry: UserPresence) -> String {
        if entry.hasPresence {
            return "\(entry.presence)"
        }
        let raw = ProtoFieldScan.varintValues(ofField: presenceField, in: entry.unknownFields.data)
        return raw.last.map { "raw=\($0)" } ?? "-"
    }

    private static func topLevelDndShape(_ entry: UserPresence) -> String {
        if entry.hasDndState {
            return "\(entry.dndState)"
        }
        let raw = ProtoFieldScan.varintValues(ofField: topLevelDndField, in: entry.unknownFields.data)
        return raw.last.map { "raw=\($0)" } ?? "-"
    }

    private static func statusDndShape(_ entry: UserPresence) -> String {
        let settings = entry.userStatus.dndSettings
        guard entry.hasUserStatus, entry.userStatus.hasDndSettings else { return "-" }
        if settings.hasDndState {
            return "\(settings.dndState)"
        }
        let raw = ProtoFieldScan.varintValues(ofField: dndStateField, in: settings.unknownFields.data)
        return raw.last.map { "raw=\($0)" } ?? "-"
    }

    private static func presenceHistogram(_ values: [String]) -> String {
        Dictionary(grouping: values) { $0 }
            .map { "\($0.key): \($0.value.count)" }
            .sorted()
            .joined(separator: ", ")
    }
}
