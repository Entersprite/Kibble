import ChatKit

/// The composer's Return, made testable: one send at a time while membership
/// is checked, and the draft cleared only if it still says what was sent, so
/// text typed during the check survives (mention non-members spec §2).
struct ComposerSendGate {
    private(set) var busy = false

    mutating func begin() -> Bool {
        guard !busy else { return false }
        busy = true
        return true
    }

    mutating func end() {
        busy = false
    }

    static func clears(draft: ComposedMessage, sent: ComposedMessage) -> Bool {
        draft == sent
    }
}
