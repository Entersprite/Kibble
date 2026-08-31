import Foundation

/// How loudly a conversation notifies.
///
/// This type is deliberately faithful to the wire rather than convenient.
/// Chat's `GroupNotificationSettings` has **two independent axes**, both
/// present in the same message:
///
/// - `state`, one of `{MUTED, UNMUTED}`, which is what a DM and a flat group
///   actually use;
/// - `room_state`, one of
///   `{NOTIFY_ALWAYS, NOTIFY_LESS_WITH_NEW_THREADS, NOTIFY_LESS, NOTIFY_NEVER}`,
///   which is what a threaded room uses.
///
/// So this enum models the second axis, and `Conversation.isMuted` models the
/// first. It would be easy to collapse both into one lossy scale — "loud,
/// quiet, silent" — and that is exactly what is not done here: there is no real
/// data yet on which combinations occur together, whether `room_state` is even
/// populated for a flat group, or which axis wins when they disagree. Inventing
/// a single scale now would bake a guess into the seam and then hide it, and
/// unpicking it later would mean a wire-format change. When the combinations
/// have been observed against a live account, a lossy convenience view can be
/// added *on top* of this without touching the protocol.
///
/// **[Verify]** the enum names above are read from the vendored
/// `googlechat.proto` in this repo; the semantics of each level are not
/// documented anywhere we control.
public enum NotificationLevel: Codable, Hashable, Sendable {
    case always
    case lessWithNewThreads
    case less
    case never
    case unknown(String)

    init(wire: String) {
        switch wire {
        case "always": self = .always
        case "lessWithNewThreads": self = .lessWithNewThreads
        case "less": self = .less
        case "never": self = .never
        default: self = .unknown(wire)
        }
    }

    var wire: String {
        switch self {
        case .always: "always"
        case .lessWithNewThreads: "lessWithNewThreads"
        case .less: "less"
        case .never: "never"
        case let .unknown(raw): raw
        }
    }

    public init(from decoder: any Decoder) throws {
        try self.init(wire: WireString.decode(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try WireString.encode(wire, to: encoder)
    }
}
