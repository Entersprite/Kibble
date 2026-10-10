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
}
