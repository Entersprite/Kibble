import ChatKit

extension MessageBubble {
    /// "Alex Lee, 3:25 PM": the row's sender and time, which a continuing
    /// row does not draw. The header is hidden from VoiceOver, so every row
    /// says the same thing.
    var accessibilityLabel: String {
        let sender = message.sender == state.me ? "You" : Display.name(
            of: message.sender,
            in: state.directory
        )
        return "\(sender), \(Display.timestamp(of: message.createdAt))"
    }
}
