import ChatKit
import SwiftUI

/// The actual last row's bottom determines whether arrivals should follow.
/// A tall message becoming partly visible does not mean its end is visible.
///
/// It also reports the last row growing while its end was in view - a link
/// card unfurling, a first reaction, a thread mark arriving - so the list can
/// keep the newest end in view, as it does for a new message. Height and
/// nearness are read in one measurement, so growth larger than the
/// near-bottom margin still counts as growth seen from the bottom rather
/// than as the person scrolling away.
struct TranscriptEndTracking: ViewModifier {
    let id: Message.ID
    /// The newest message when the list drew this row.
    let drawnNewest: Message.ID?
    /// The newest message now, for when the row leaves (`TranscriptNewest`).
    let newest: TranscriptNewest
    @Binding var nearBottom: Bool
    /// Asked to scroll to the newest end after the last row grew; `nil`
    /// follows nothing.
    var grew: (() -> Void)?

    private var isLast: Bool {
        newest.id == id
    }

    struct End: Equatable {
        var height: CGFloat
        var nearBottom: Bool
    }

    func body(content: Content) -> some View {
        let drawnLast = drawnNewest == id
        return content
            .onGeometryChange(for: End.self) { geometry in
                End(
                    height: geometry.size.height,
                    nearBottom: drawnLast && Self.isNearBottom(
                        rowHeight: geometry.size.height,
                        viewport: geometry.bounds(of: .scrollView)
                    )
                )
            } action: { old, new in
                guard isLast else { return }
                // The list's own word too: placing a search's target sets it
                // false while rows are still settling their heights.
                if nearBottom, Self.followsGrowth(from: old, to: new), let grew {
                    // Still at the bottom: the scroll that follows says so.
                    grew()
                } else if nearBottom != new.nearBottom {
                    nearBottom = new.nearBottom
                }
            }
            // Read when the row leaves, not when it was last drawn: a row
            // that is still the newest left because the list scrolled away
            // from it. One that is no longer the newest was replaced or
            // removed, as a sent message's row is when the service confirms
            // it, and the list has not moved.
            .onDisappear {
                if isLast {
                    nearBottom = false
                }
            }
    }

    nonisolated static func isNearBottom(rowHeight: CGFloat, viewport: CGRect?) -> Bool {
        guard let viewport else { return false }
        return viewport.maxY >= rowHeight - 100 && viewport.minY < rowHeight
    }

    /// The row got taller while its end was in view. Half a point of
    /// rounding is not growth.
    nonisolated static func followsGrowth(from old: End, to new: End) -> Bool {
        old.nearBottom && new.height > old.height + 0.5
    }
}

/// The transcript's newest message as of its latest render. A class, so
/// keeping it current draws nothing, and so a row that leaves reads the
/// newest as it is then rather than as it was when the row was last drawn.
///
/// Measured in the hosted transcript: a sent message's row is replaced when
/// the service confirms it, and clearing `nearBottom` on that row's leaving
/// left the transcript believing it had scrolled away. Jump to Latest showed
/// at the bottom, and the newest row's growth was no longer followed; new
/// arrivals read the same flag.
final class TranscriptNewest {
    private(set) var id: Message.ID?

    /// Records the newest of `messages` while the list draws them.
    func track(_ messages: [Message]) -> Message.ID? {
        id = messages.last?.id
        return id
    }
}
