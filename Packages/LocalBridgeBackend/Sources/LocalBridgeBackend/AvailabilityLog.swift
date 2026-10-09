import ChatKit
import Foundation
import GChatBridgeCore
import os

/// What each answer about your availability said, in the unified log, so a
/// live run can be read with `log show` instead of being copied out of the
/// sandbox (session 62, Away that never stuck). Field presence, booleans and
/// the Do not disturb state only: no id, no status text, nothing private.
///
///     /usr/bin/log show --last 10m --predicate \
///         'subsystem == "com.entersprite.kibble" && category == "availability"'
///
/// The full path, because in zsh `log` is a shell builtin.
///
/// Every line names the order the set calls go in (`order=dnd-first`), so a
/// log from a build before session 62 cannot be read as this one's.
enum AvailabilityLog {
    private static let log = Logger(subsystem: "com.entersprite.kibble", category: "availability")

    static func answer(_ call: String, _ status: UserStatus?, requested: Availability?, shown: Availability) {
        let fields = status.map(describe) ?? "no user_status"
        log.notice(
            """
            order=dnd-first call=\(call, privacy: .public) requested=\(name(requested), privacy: .public) \
            \(fields, privacy: .public) shown=\(name(shown), privacy: .public)
            """
        )
    }

    /// A refused availability call, with what Google said: the status alone
    /// named no reason for Do not disturb's 400 (session 62). Only the two
    /// availability calls, whose requests carry nothing private; the body cut
    /// to 400 characters, anything but printable ASCII as `·`, because a
    /// refusal's body may be binary.
    static func refusal(_ refusal: APIRefusal, current: Availability?) {
        guard ["set_dnd_duration", "set_presence_shared"].contains(refusal.method) else { return }
        let text = String(refusal.body.prefix(400).map { byte in
            (0x20 ... 0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "·"
        })
        log.notice(
            """
            order=dnd-first refused call=\(refusal.method, privacy: .public) \
            status=\(refusal.status, privacy: .public) current=\(name(current), privacy: .public) \
            bodyLength=\(refusal.body.count, privacy: .public) body=\(text, privacy: .public)
            """
        )
    }

    private static func describe(_ status: UserStatus) -> String {
        let shared = status.hasPresenceShared ? String(status.presenceShared) : "absent"
        let dnd = status.hasDndSettings && status.dndSettings.hasDndState
            ? String(describing: status.dndSettings.dndState) : "absent"
        return "presenceShared=\(shared) dndState=\(dnd)"
    }

    private static func name(_ availability: Availability?) -> String {
        switch availability {
        case .automatic: "automatic"
        case .away: "away"
        case .doNotDisturb: "doNotDisturb"
        case let .unknown(raw): "unknown(\(raw))"
        case nil: "-"
        }
    }
}
