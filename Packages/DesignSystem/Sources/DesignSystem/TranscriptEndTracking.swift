import SwiftUI

/// The actual last row's bottom determines whether arrivals should follow.
/// A tall message becoming partly visible does not mean its end is visible.
struct TranscriptEndTracking: ViewModifier {
    let isLast: Bool
    @Binding var nearBottom: Bool

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: Bool.self) { geometry in
                isLast && Self.isNearBottom(
                    rowHeight: geometry.size.height,
                    viewport: geometry.bounds(of: .scrollView)
                )
            } action: { visible in
                if isLast, nearBottom != visible {
                    nearBottom = visible
                }
            }
            .onDisappear {
                if isLast {
                    nearBottom = false
                }
            }
    }

    static func isNearBottom(rowHeight: CGFloat, viewport: CGRect?) -> Bool {
        guard let viewport else { return false }
        return viewport.maxY >= rowHeight - 100 && viewport.minY < rowHeight
    }
}
