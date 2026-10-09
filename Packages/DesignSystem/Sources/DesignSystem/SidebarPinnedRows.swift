import SwiftUI

/// The Mentions row (the mentions-list spec §4): an `at` symbol, verified
/// present with `NSImage(systemSymbolName:accessibilityDescription:)`, and a
/// badge of unread mentions. It has no context menu and no rules.
struct MentionsSidebarRow: View {
    let unread: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "at")
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text("Mentions")
                .lineLimit(1)
            Spacer(minLength: 4)
            if let badge = MentionsPresentation.badge(unread: unread) {
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(badge) unread")
            }
        }
        .padding(.vertical, 1)
    }
}
