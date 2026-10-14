import Foundation

/// Small scroll-geometry values avoid propagating the full geometry through
/// presentation state. Paging requires user movement toward an edge; initial
/// placement and programmatic search jumps never start a paging cascade.
struct TranscriptViewport: Equatable {
    let offset: CGFloat
    let contentHeight: CGFloat
    let visibleHeight: CGFloat

    var nearBottom: Bool {
        contentHeight - visibleHeight - offset <= 100
    }

    enum Page: Equatable {
        case older
        case newer
    }

    static func page(
        previous: Self, current: Self, userScrolling: Bool
    ) -> Page? {
        guard userScrolling else { return nil }
        if current.offset < previous.offset, current.offset < 240 {
            return .older
        }
        if current.offset > previous.offset,
           current.contentHeight - current.visibleHeight - current.offset < 240 {
            return .newer
        }
        return nil
    }
}
