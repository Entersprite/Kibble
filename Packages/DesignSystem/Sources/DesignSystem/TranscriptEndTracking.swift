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
    let isLast: Bool
    @Binding var nearBottom: Bool
    /// Asked to scroll to the newest end after the last row grew; `nil`
    /// follows nothing.
    var grew: (() -> Void)?

    struct End: Equatable {
        var height: CGFloat
        var nearBottom: Bool
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: End.self) { geometry in
                End(
                    height: geometry.size.height,
                    nearBottom: isLast && Self.isNearBottom(
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
