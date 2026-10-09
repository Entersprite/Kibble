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

/// The Threads row (threads spec §5.3): followed threads, with a badge of the
/// unread ones. No context menu and no rules, like the Mentions row.
struct ThreadsSidebarRow: View {
    let unread: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ThreadsPresentation.rowSymbol)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(ThreadsPresentation.title)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let badge = ThreadsPresentation.badge(unread: unread) {
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
