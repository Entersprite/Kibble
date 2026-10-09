import CoreGraphics
import Testing
@testable import DesignSystem

/// The transcript and the thread side by side (session 58): half and half when
/// a thread opens, a divider the person drags, and neither side below its
/// minimum while there is room for both.
struct ThreadSplitLayoutTests {
    @Test func aThreadOpensAtHalf() {
        let layout = ThreadSplitLayout(total: 1001, share: ThreadSplitLayout.initialShare)
        #expect(layout.panel == 500)
        #expect(layout.transcript == 500)
    }

    /// The divider takes its width from the two sides, never more.
    @Test func theSidesAndTheDividerFillTheWidth() {
        let layout = ThreadSplitLayout(total: 893.5, share: 0.37)
        #expect(layout.transcript + ThreadSplitLayout.dividerWidth + layout.panel == 893.5)
    }

    @Test func theShareHoldsAsTheWindowResizes() {
        #expect(ThreadSplitLayout(total: 1001, share: 0.3).panel == 300)
        #expect(ThreadSplitLayout(total: 2001, share: 0.3).panel == 600)
    }

    @Test func neitherSideGoesBelowItsMinimum() {
        let narrowPanel = ThreadSplitLayout(total: 1001, share: 0.05)
        #expect(narrowPanel.panel == ThreadSplitLayout.minimumWidth)
        let narrowTranscript = ThreadSplitLayout(total: 1001, share: 0.95)
        #expect(narrowTranscript.transcript == ThreadSplitLayout.minimumWidth)
    }

    /// Below room for both minimums, each side gets half, whatever the share.
    @Test func tooNarrowForBothSplitsEvenly() {
        for share in [0.1, 0.5, 0.9] as [CGFloat] {
            let layout = ThreadSplitLayout(total: 401, share: share)
            #expect(layout.panel == 200)
            #expect(layout.transcript == 200)
        }
    }

    @Test func aDragSetsTheShareFromTheDividersPosition() {
        #expect(ThreadSplitLayout.share(dividerAt: 300, total: 1001) == 0.7)
    }

    /// What a drag stores is what is drawn, so a drag past a minimum does not
    /// come back when the window grows.
    @Test func aDragPastAMinimumStopsAtIt() {
        #expect(ThreadSplitLayout.share(dividerAt: 900, total: 1001) == 0.26)
        #expect(ThreadSplitLayout.share(dividerAt: -50, total: 1001) == 0.74)
    }
}
