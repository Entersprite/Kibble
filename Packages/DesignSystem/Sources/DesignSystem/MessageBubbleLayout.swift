import SwiftUI

/// A text bubble's widest: the smaller of three quarters of the transcript's
/// column and 560 points, about 80 characters at the 13-point body size, so
/// a long message on a wide window wraps where it can still be read in
/// lines. Pictures and cards keep their own limits (`AttachmentLayout`,
/// `LinkCardLayout`, `AppCardView`).
enum MessageBubbleLayout {
    static let maxTextWidth: CGFloat = 560
    static let columnShare: CGFloat = 0.75
    /// The picture beside someone else's message, and the empty column a
    /// continuing row keeps in its place.
    static let avatarSide: CGFloat = 26
    static let spacing: CGFloat = 8
    /// The room a row always leaves on the side away from its sender.
    static let opposite: CGFloat = 60

    /// What a row spends beside its bubble's column: the spacer's minimum
    /// and, for someone else's message, the picture. The column is offered
    /// the row's width less this, measured in an `NSHostingView`.
    static func reserve(isMine: Bool) -> CGFloat {
        isMine ? opposite + spacing : avatarSide + spacing + spacing + opposite
    }

    /// `row` is the transcript's column, which a row spans.
    static func maxTextWidth(row: CGFloat) -> CGFloat {
        guard row.isFinite, row > 0 else { return maxTextWidth }
        return min(maxTextWidth, (row * columnShare).rounded(.down))
    }

    /// Your own bubbles are system blue, as in Messages: a fixed color, not
    /// the accent, so they read as yours whatever the accent is. The system
    /// color adapts to Increase Contrast and to dark appearance.
    static let ownFill = Color.blue
}

/// Offers its content at most `MessageBubbleLayout.maxTextWidth(row:)` and
/// takes the content's own size, so a long text wraps at the limit and a
/// short one stays as narrow as its words (`frame(maxWidth:)` would grow to
/// the limit). The row's width is worked out from this view's own offer plus
/// the row's `reserve`, during layout: a width kept in state would arrive a
/// pass late, after the transcript had placed its rows.
struct BubbleWidthLimit: Layout {
    let reserve: CGFloat

    func limit(for proposal: ProposedViewSize) -> CGFloat {
        guard let width = proposal.width, width.isFinite else { return MessageBubbleLayout.maxTextWidth }
        return min(width, MessageBubbleLayout.maxTextWidth(row: width + reserve))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return content.sizeThatFits(ProposedViewSize(width: limit(for: proposal), height: proposal.height))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        subviews.first?.place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

/// Add Reaction, shown while the pointer is over a row, beside the message
/// and centered on it, in the room the row's spacer keeps, so nothing moves.
/// Only until the message has reactions, whose row ends with an add button
/// of its own. VoiceOver reaches the same action through the row's actions.
///
/// Always in the tree and only faded: inside an `if`, an overlay's explicit
/// alignment guide was ignored (measured headless), which put the button
/// over the bubble's edge.
struct AddReactionHoverButton: View {
    let isMine: Bool
    let shown: Bool
    let action: () -> Void

    var body: some View {
        let mine = isMine
        Button(action: action) {
            Label("Add Reaction", systemImage: MessageMenuSymbols.moreEmoji)
                .labelStyle(.iconOnly)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(.quinary, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .alignmentGuide(mine ? HorizontalAlignment.leading : .trailing) { dimensions in
            mine ? dimensions[.trailing] + 6 : dimensions[.leading] - 6
        }
        .help("Add Reaction")
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .accessibilityHidden(true)
    }
}
