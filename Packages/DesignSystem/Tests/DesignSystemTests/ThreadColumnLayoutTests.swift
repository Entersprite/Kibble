import CoreGraphics
import Testing
@testable import DesignSystem

/// The width the thread column reopens at (`ThreadColumnLayout`). AppKit's
/// split view does the rest, so the arithmetic is all there is to test here.
struct ThreadColumnLayoutTests {
    @Test func aFirstOpeningTakesHalf() {
        #expect(ThreadColumnLayout.openingWidth(available: 1001, remembered: nil) == 501)
        #expect(ThreadColumnLayout.openingWidth(available: 800, remembered: nil) == 400)
    }

    @Test func aReopeningKeepsTheLastWidth() {
        #expect(ThreadColumnLayout.openingWidth(available: 1000, remembered: 320) == 320)
    }

    /// A width remembered in a wider window is clamped to leave the
    /// conversation its minimum, and one too narrow is raised to the thread's.
    @Test func bothColumnsKeepTheMinimum() {
        let minimum = ThreadColumnLayout.minimumWidth
        #expect(ThreadColumnLayout.openingWidth(available: 700, remembered: 600) == 700 - minimum)
        #expect(ThreadColumnLayout.openingWidth(available: 700, remembered: 100) == minimum)
    }

    /// Below room for both minimums, each gets half, so neither vanishes.
    @Test func belowBothMinimumsEachGetsHalf() {
        #expect(ThreadColumnLayout.openingWidth(available: 400, remembered: nil) == 200)
        #expect(ThreadColumnLayout.openingWidth(available: 400, remembered: 380) == 200)
        #expect(ThreadColumnLayout.openingWidth(available: 0, remembered: 300) == 0)
    }

    /// The conversation runs under the floating sidebar from x = 0, so half of
    /// its frame left it the sidebar's width short of the thread (session 65,
    /// measured: 405 pt visible beside a 550-pt thread at 1,100). What the two
    /// share starts at the sidebar's trailing edge.
    @Test func theShareStartsAtTheSidebarsEdge() {
        let shared = ThreadColumnLayout.sharedWidth(
            splitWidth: 1100, contentLeading: 0, sidebarTrailing: 240, divider: 1
        )
        #expect(shared == 859)
        #expect(ThreadColumnLayout.sharedWidth(
            splitWidth: 1100, contentLeading: 300, sidebarTrailing: 240, divider: 1
        ) == 799)
        #expect(ThreadColumnLayout.sharedWidth(
            splitWidth: 1100, contentLeading: 0, sidebarTrailing: nil, divider: 1
        ) == 1099)
    }
}

/// The sidebar's width, which SwiftUI's three-column split does not apply
/// (session 65, measured: AppKit's defaults, 140 minimum, 144 wide).
struct SidebarColumnLayoutTests {
    /// Narrower than the minimum, which AppKit's default and every width saved
    /// before this fix were, opens at the ideal width.
    @Test func aNarrowSidebarOpensAtTheIdealWidth() {
        #expect(SidebarColumnLayout.correctedWidth(current: 144) == SidebarColumnLayout.idealWidth)
        #expect(SidebarColumnLayout.correctedWidth(current: SidebarColumnLayout.minimumWidth - 1) == 240)
    }

    /// A width the person chose, at or past the minimum, is kept; and a
    /// sidebar not laid out yet is left alone.
    @Test func aChosenWidthIsKept() {
        #expect(SidebarColumnLayout.correctedWidth(current: SidebarColumnLayout.minimumWidth) == nil)
        #expect(SidebarColumnLayout.correctedWidth(current: 320) == nil)
        #expect(SidebarColumnLayout.correctedWidth(current: 0) == nil)
    }
}
