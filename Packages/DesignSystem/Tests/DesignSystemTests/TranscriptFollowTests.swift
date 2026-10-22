import SwiftUI
import Testing
@testable import DesignSystem

struct TranscriptFollowTests {
    @Test func onlyAnIntentionalScrollLeavesTheNewest() {
        let grown = TranscriptEnd(distance: 600)
        #expect(TranscriptFollow.effect(
            following: true, scrolling: false, canFollow: true, settled: true, at: grown
        ) == .pin)
        #expect(TranscriptFollow.effect(
            following: true, scrolling: true, canFollow: true, settled: true, at: grown
        ) == .detach)
        #expect(TranscriptFollow.effect(
            following: false, scrolling: false, canFollow: true, settled: true, at: grown
        ) == nil)
        #expect(TranscriptFollow.effect(
            following: false, scrolling: true, canFollow: true, settled: true, at: TranscriptEnd(distance: 8)
        ) == .follow)
    }

    @Test func loadingNewerHistoryAndRestoringAPlacePreventPinning() {
        #expect(TranscriptFollow.effect(
            following: true, scrolling: false, canFollow: false, settled: true,
            at: TranscriptEnd(distance: 100)
        ) == .detach)
        #expect(TranscriptFollow.effect(
            following: true, scrolling: false, canFollow: true, settled: false,
            at: TranscriptEnd(distance: 100)
        ) == nil)
        #expect(TranscriptFollow.effect(
            following: false, scrolling: true, canFollow: false, settled: true, at: TranscriptEnd(distance: 0)
        ) == nil)
    }

    @Test func theEndMustClearTheComposerEvenWhenATallMessageIsVisible() {
        func end(offset: CGFloat) -> TranscriptEnd {
            TranscriptEnd(ScrollGeometry(
                contentOffset: CGPoint(x: 0, y: offset), contentSize: CGSize(width: 500, height: 2000),
                contentInsets: EdgeInsets(top: 0, leading: 0, bottom: 60, trailing: 0),
                containerSize: CGSize(width: 500, height: 440)
            ))
        }
        #expect(end(offset: 1000).distance > TranscriptFollow.reach)
        // The text's end is visible here, but lies behind the 60pt composer.
        #expect(end(offset: 1560).distance == 60)
        #expect(end(offset: 1620).distance == 0)
    }
}
