import SwiftUI

/// A column's title in the window toolbar's band: the thread panel's always,
/// and the conversation's while a thread is open beside it (`ThreadSplit`).
///
/// **In the toolbar's own fonts**, read off AppKit's title fields (session
/// 63): 13-pt bold over 11-pt regular, or 15-pt semibold with no subtitle.
/// The conversation's title changes hands when a thread opens, and these keep
/// it from moving when it does: rendered both ways, the lines matched to the
/// pixel in height and width. In an active window `.primary` and `.secondary`
/// measured within 5% of AppKit's title on the owner's screenshot; inactive,
/// AppKit dims both lines alike, and `.secondary` is the nearest match.
///
/// Only text. In the band, AppKit's title container spans the detail column
/// and takes every click, so a button drawn here never fires (session 63,
/// measured by hit test and posted clicks).
struct ColumnTitle: View {
    let title: String
    let subtitle: String
    @Environment(\.appearsActive) private var appearsActive

    /// Where AppKit's title text starts in its column, with the sidebar
    /// shown: its field at 18 pt, and the text 2 pt into the field (measured
    /// against a render, session 63).
    static let inset: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(subtitle.isEmpty ? .title3.weight(.semibold) : .headline)
                .foregroundStyle(appearsActive ? .primary : .secondary)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}
