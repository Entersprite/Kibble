import ChatKit
import Testing
@testable import DesignSystem

/// Back and Forward behave as a browser's: a visit drops what is ahead, a
/// step moves without recording, and a place that can no longer be shown is
/// passed over.
struct NavigationHistoryTests {
    static func chat(_ id: String, thread: String? = nil) -> NavigationPlace {
        .sidebar(.conversation(Conversation.ID(id)), thread: thread.map { MessageThread.ID($0) })
    }

    static func visited(_ places: [NavigationPlace]) -> NavigationHistory {
        var history = NavigationHistory()
        for place in places {
            history.visit(place)
        }
        return history
    }

    @Test func aNewHistoryCannotStep() {
        var history = NavigationHistory()
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
        #expect(history.back { _ in true } == nil)
        #expect(history.forward { _ in true } == nil)
        history.visit(Self.chat("a"))
        #expect(!history.canGoBack)
    }

    @Test func backAndForwardRetraceTheVisits() {
        var history = Self.visited([Self.chat("a"), .sidebar(.mentions, thread: nil), Self.chat("b")])
        #expect(history.back { _ in true } == .sidebar(.mentions, thread: nil))
        #expect(history.back { _ in true } == Self.chat("a"))
        #expect(!history.canGoBack)
        #expect(history.forward { _ in true } == .sidebar(.mentions, thread: nil))
        #expect(history.forward { _ in true } == Self.chat("b"))
        #expect(!history.canGoForward)
    }

    /// The window arrives where the step went, and that arrival is the
    /// current place, so Forward survives it.
    @Test func arrivingAtTheSteppedPlaceRecordsNothing() {
        var history = Self.visited([Self.chat("a"), Self.chat("b")])
        let place = history.back { _ in true }
        history.visit(Self.chat("a"))
        #expect(place == Self.chat("a"))
        #expect(history.canGoForward)
        #expect(history.places == [Self.chat("a"), Self.chat("b")])
    }

    @Test func aVisitAfterBackDropsWhatWasAhead() {
        var history = Self.visited([Self.chat("a"), Self.chat("b"), Self.chat("c")])
        _ = history.back { _ in true }
        _ = history.back { _ in true }
        history.visit(Self.chat("d"))
        #expect(history.places == [Self.chat("a"), Self.chat("d")])
        #expect(!history.canGoForward)
    }

    /// Opening a thread is a step of its own, so Back closes it first.
    @Test func aThreadIsItsOwnPlace() {
        var history = Self.visited([Self.chat("a"), Self.chat("a", thread: "t"), Self.chat("b")])
        #expect(history.back { _ in true } == Self.chat("a", thread: "t"))
        #expect(history.back { _ in true } == Self.chat("a"))
    }

    @Test func placesThatCannotBeShownArePassedOverAndForgotten() {
        var history = Self.visited([Self.chat("a"), Self.chat("gone"), Self.chat("b"), Self.chat("left")])
        _ = history.back { _ in true }
        let available: (NavigationPlace) -> Bool = { $0 != Self.chat("gone") && $0 != Self.chat("left") }
        #expect(history.back(where: available) == Self.chat("a"))
        #expect(history.places == [Self.chat("a"), Self.chat("b"), Self.chat("left")])
        #expect(history.forward(where: available) == Self.chat("b"))
        #expect(history.forward(where: available) == nil)
        #expect(history.places == [Self.chat("a"), Self.chat("b")])
        #expect(history.current == Self.chat("b"))
    }

    @Test func theOldestPlacesFallOffPastTheLimit() {
        let places = (0 ... NavigationHistory.limit).map { Self.chat("c\($0)") }
        let history = Self.visited(places)
        #expect(history.places.count == NavigationHistory.limit)
        #expect(history.places.first == Self.chat("c1"))
        #expect(history.current == places.last)
    }
}
