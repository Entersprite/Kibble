import ChatKit
import Foundation
import GChatBridgeCore
import SwiftProtobuf

/// The in-a-meeting spike (session 32): where does Chat's "In a meeting" come
/// from? No vendored proto names a calendar or meeting status, so this
/// reports the fields **no proto names**, wherever a person's status travels:
/// `get_user_presence`, `get_user_status` and `get_self_user_status`.
///
/// Run once in a meeting and once out of one, and compare. A field that
/// appears only then is the answer. The local user's own entry is reported
/// separately, labelled `self` - being in a meeting yourself is the easiest
/// condition to arrange.
///
/// **Shapes, never values.** A field is its number. A small varint - 32 or
/// less, the size of an enum - also shows its value (`9=2`), the same
/// posture `ProtoFieldScan.varintValues`' doc comment takes toward ordinals.
/// A length-delimited field is expanded when its bytes parse cleanly as a
/// message (`6{1,2=1}`), and is `6:bytes` otherwise. A string could in
/// principle parse as a message by chance; the expansion is a hint, and no
/// byte of it is ever printed.
extension APIProbeReport {
    /// The largest varint printed as a value rather than as `:varint`.
    private static let largestOrdinal: UInt64 = 32
    /// How deep a nested message is expanded.
    private static let shapeDepth = 3

    /// The unnamed fields of `message`: what `unknownFields` holds, as a shape.
    /// `-` when there are none.
    static func unnamedShape(of message: some SwiftProtobuf.Message) -> String {
        let shape = shape(of: message.unknownFields.data, depth: shapeDepth)
        return shape.isEmpty ? "-" : shape
    }

    /// Field numbers in order, one entry per distinct number.
    static func shape(of data: Data, depth: Int) -> String {
        let scan = ProtoFieldScan.fields(in: data)
        var parts: [String] = []
        for number in Set(scan.fields.map(\.number)).sorted() {
            guard let field = scan.fields.first(where: { $0.number == number }) else { continue }
            parts.append(describe(field, in: data, depth: depth))
        }
        if scan.truncated {
            parts.append("…")
        }
        return parts.joined(separator: ",")
    }

    private static func describe(_ field: ProtoField, in data: Data, depth: Int) -> String {
        switch field.wireType {
        case 0:
            let value = ProtoFieldScan.varintValues(ofField: field.number, in: data).first ?? 0
            return value <= largestOrdinal ? "\(field.number)=\(value)" : "\(field.number):varint"
        case 2:
            guard depth > 0, let payload = ProtoFieldScan.payloads(ofField: field.number, in: data).first,
                  !payload.isEmpty
            else { return "\(field.number):bytes" }
            let nested = ProtoFieldScan.fields(in: payload)
            // Plausible as a message: read to the end, and field numbers a
            // proto would use. A string of text rarely parses this cleanly.
            guard !nested.truncated, !nested.fields.isEmpty, nested.fields.allSatisfy({ $0.number < 1000 })
            else { return "\(field.number):bytes" }
            return "\(field.number){\(shape(of: payload, depth: depth - 1))}"
        default:
            return "\(field.number):fixed"
        }
    }

    /// One line of shapes and how many entries carried each.
    static func shapeTally(_ shapes: [String]) -> String {
        Dictionary(grouping: shapes) { $0 }
            .map { "\($0.key): \($0.value.count)" }
            .sorted()
            .joined(separator: ", ")
    }

    /// The unnamed-field lines for a `get_user_presence` answer, with the
    /// local user's own entry apart.
    static func unnamedPresenceLines(_ response: GetUserPresenceResponse, selfUserID: String?) -> [String] {
        let entries = response.userPresences
        var lines = [
            "  unnamed fields, UserPresence [\(shapeTally(entries.map { unnamedShape(of: $0) }))]",
            "  unnamed fields, its user_status "
                + "[\(shapeTally(entries.map { unnamedShape(of: $0.userStatus) }))]",
            "  unnamed fields, its custom_status "
                + "[\(shapeTally(entries.map { unnamedShape(of: $0.userStatus.customStatus) }))]"
        ]
        guard let selfUserID, let mine = entries.first(where: { $0.userID.id == selfUserID }) else {
            lines.append("  self: not in the answer")
            return lines
        }
        lines.append(
            "  self: presence \(mine.hasPresence ? "\(mine.presence)" : "-"), "
                + "dnd \(mine.hasDndState ? "\(mine.dndState)" : "-"), "
                + "custom status \(mine.userStatus.hasCustomStatus ? "present" : "-"), "
                + "unnamed UserPresence \(unnamedShape(of: mine)), "
                + "user_status \(unnamedShape(of: mine.userStatus))"
        )
        return lines
    }

    /// `get_user_status` over the same people, which purple declares
    /// (`googlechat_connection.h:88`) and never calls - a second place a
    /// person's status may travel.
    static func appendUserStatusSummary(
        ids: [ChatKit.Member.ID],
        selfUserID: String?,
        client: ProtoAPIClient,
        lines: inout [String]
    ) async {
        lines.append("user status summary (get_user_status):")
        guard !ids.isEmpty else {
            lines.append("  nobody to ask about")
            return
        }
        var request = GetUserStatusRequest()
        request.requestHeader = APIRequestHeader.make()
        request.userIds = ids.map { id in
            var userID = UserId()
            userID.id = id.rawValue
            return userID
        }
        let response: GetUserStatusResponse
        do {
            response = try await client.call(.getUserStatus, request)
        } catch {
            lines.append("  FAILED: \(safeDescription(of: error))")
            return
        }
        lines.append(contentsOf: userStatusLines(response, selfUserID: selfUserID))
    }

    static func userStatusLines(_ response: GetUserStatusResponse, selfUserID: String?) -> [String] {
        let statuses = response.userStatuses
        var lines = [
            "  entries returned: \(statuses.count), "
                + "with dnd_settings: \(statuses.count(where: \.hasDndSettings)), "
                + "with custom status: \(statuses.count(where: \.hasCustomStatus))",
            "  unnamed fields, UserStatus [\(shapeTally(statuses.map { unnamedShape(of: $0) }))]",
            "  unnamed fields, top level [\(unnamedShape(of: response))]"
        ]
        if let selfUserID, let mine = statuses.first(where: { $0.userID.id == selfUserID }) {
            lines.append("  self: unnamed UserStatus \(unnamedShape(of: mine))")
        } else {
            lines.append("  self: not in the answer")
        }
        return lines
    }

    /// The local user's own status, asked for on its own: the call the
    /// probe's first section already verifies, scanned for what it does not
    /// name.
    static func appendSelfStatusSummary(client: ProtoAPIClient, lines: inout [String]) async {
        lines.append("self status (get_self_user_status):")
        let response: GetSelfUserStatusResponse
        do {
            response = try await client.call(.getSelfUserStatus, GetSelfUserStatusRequest())
        } catch {
            lines.append("  FAILED: \(safeDescription(of: error))")
            return
        }
        lines.append(contentsOf: selfStatusLines(response))
    }

    static func selfStatusLines(_ response: GetSelfUserStatusResponse) -> [String] {
        let status = response.userStatus
        let dnd = status.hasDndSettings && status.dndSettings
            .hasDndState ? "\(status.dndSettings.dndState)" : "-"
        return [
            "  dnd \(dnd), custom status \(status.hasCustomStatus ? "present" : "-")",
            "  unnamed fields, UserStatus [\(unnamedShape(of: status))]",
            "  unnamed fields, custom_status [\(unnamedShape(of: status.customStatus))]",
            "  unnamed fields, top level [\(unnamedShape(of: response))]"
        ]
    }
}
