import ChatKit
import Foundation

/// The composer's Return, made testable: one send at a time while membership
/// is checked, and the draft cleared only if it still says what was sent, so
/// text typed during the check survives (mention non-members spec §2).
struct ComposerSendGate {
    private(set) var attempt: UUID?

    mutating func begin() -> UUID? {
        guard attempt == nil else { return nil }
        let id = UUID()
        attempt = id
        return id
    }

    mutating func cancel() {
        attempt = nil
    }

    /// Compared without modes: the confirmation sends the draft with modes
    /// set, and it is still the same draft (review finding 1).
    static func clears(draft: ComposedMessage, sent: ComposedMessage) -> Bool {
        func plain(_ message: ComposedMessage) -> ComposedMessage {
            message.settingMode(.mention, for: message.mentions.compactMap { mention in
                if case let .user(id) = mention.target {
                    id
                } else {
                    nil
                }
            })
        }
        return plain(draft) == plain(sent)
    }
}
