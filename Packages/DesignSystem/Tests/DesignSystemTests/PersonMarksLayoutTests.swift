import AppKit
import ChatKit
import SwiftUI
import Testing
@testable import DesignSystem

/// `PersonMarks` sits in every sidebar row and the footer. With nothing to
/// draw it must take no room, or every name truncates a stack-spacing sooner
/// (the whole-branch review's finding 3, measured the same way). An empty
/// view, an empty `TimelineView` included, still takes the spacing, so
/// nothing-to-draw is no view at all.
@MainActor
struct PersonMarksLayoutTests {
    private func width(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.width
    }

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func nothingToDrawIsNoView() {
        let busy = CalendarSchedule.Entry(
            start: now,
            end: now.addingTimeInterval(60),
            kind: .busy,
            until: nil
        )
        #expect(PersonMarks(status: nil, calendar: nil, now: now) == nil)
        // Busy is shown in words only, so it alone draws no mark.
        #expect(PersonMarks(status: nil, calendar: busy, now: now) == nil)
        #expect(PersonMarks(status: MemberStatus(emoji: "🎧"), calendar: nil, now: now) != nil)
    }

    /// The row's own shape: a timeline around the stack, the marks only when
    /// there are some. A boundary to wait for takes no room.
    @Test func aRowWaitingForABoundaryIsAsWideAsOneWithoutMarks() {
        let bare = width(HStack(spacing: 8) { Text("Maya Okafor") })
        let waiting = width(TimelineView(.explicit([Date.now.addingTimeInterval(3600)])) { _ in
            HStack(spacing: 8) {
                Text("Maya Okafor")
                if let marks = PersonMarks(status: nil, calendar: nil, now: .now) {
                    marks
                }
            }
        })
        #expect(waiting == bare)
    }

    @Test func somethingToDrawTakesRoom() {
        let bare = width(HStack(spacing: 8) { Text("Maya Okafor") })
        let marked = width(HStack(spacing: 8) {
            Text("Maya Okafor")
            if let marks = PersonMarks(status: MemberStatus(emoji: "🎧"), calendar: nil, now: now) {
                marks
            }
        })
        #expect(marked > bare)
    }
}
