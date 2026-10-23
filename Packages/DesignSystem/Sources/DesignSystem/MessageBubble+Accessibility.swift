import ChatKit
import SwiftUI

extension MessageBubble {
    /// Beside the message on its open side, away from the picture, where
    /// nothing else hangs. Always in the overlay and faded unless pinned, so
    /// its guide holds (an `if` would drop it, CLAUDE.md); VoiceOver hears
    /// "Pinned" in the row's label instead.
    var pinGlyph: some View {
        let mine = message.sender == state.me
        return Image(systemName: PinStyle.symbol)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .opacity(state.isPinned ? 1 : 0)
            .accessibilityHidden(true)
            .alignmentGuide(mine ? HorizontalAlignment.leading : .trailing) { dimensions in
                mine ? dimensions[.trailing] + PinStyle.glyphGap : dimensions[.leading] - PinStyle.glyphGap
            }
    }

    /// "Alex Lee, 3:25 PM": the row's sender and time, which a continuing
    /// row does not draw. The header is hidden from VoiceOver, so every row
    /// says the same thing. A pinned row ends with "Pinned", which its glyph
    /// shows.
    var accessibilityLabel: String {
        let sender = message.sender == state.me ? "You" : Display.name(
            of: message.sender,
            in: state.directory
        )
        let label = "\(sender), \(Display.timestamp(of: message.createdAt))"
        return state.isPinned ? label + ", Pinned" : label
    }
}
