import ChatKit
import Synchronization

/// Checked at submission, including after a slow prior request. Unknown account settings withhold.
public final class TypingPrivacyGate: Sendable {
    private let value = Mutex<NotificationSettings?>(nil)
    public init() {}
    public func set(_ settings: NotificationSettings?) {
        value.withLock { $0 = settings }
    }

    func allows(_ conversation: Conversation) -> Bool {
        value.withLock { $0?.resolve(for: conversation).sharesTyping == true }
    }
}
