import ChatKit
import SwiftUI

/// A person's status beside their name: its emoji, a stock glyph for a custom
/// image emoji, or a small bubble for text alone - with the words on hover.
///
/// A custom emoji's image is not drawn: its URL needs authentication and
/// expires (`MemberStatus.customEmojiShortcode`), so `face.smiling` stands in
/// and the tooltip names the shortcode. `[Verify]` how Google's own client
/// draws one. Both symbol names were checked with
/// `NSImage(systemSymbolName:accessibilityDescription:)`, since a wrong one
/// compiles and renders as nothing.
struct StatusMark: View {
    let status: MemberStatus

    var body: some View {
        mark
            .font(.caption)
            .help(Display.statusSummary(status))
            .accessibilityElement()
            .accessibilityLabel("Status: \(Display.statusSummary(status))")
    }

    @ViewBuilder private var mark: some View {
        if let emoji = status.emoji {
            Text(emoji)
        } else if status.customEmojiShortcode != nil {
            Image(systemName: "face.smiling").foregroundStyle(.secondary)
        } else {
            Image(systemName: "text.bubble").foregroundStyle(.tertiary)
        }
    }
}
