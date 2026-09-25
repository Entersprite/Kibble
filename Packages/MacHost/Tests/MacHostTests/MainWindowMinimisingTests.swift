import AppKit
import Foundation
import Testing
@testable import MacHost

/// The viewing gate is about the main window, and AppKit posts minimise
/// notifications for every window.
@MainActor
struct MainWindowMinimisingTests {
    /// Stand-ins for two windows: only identity matters to the filter.
    private let main = NSObject()
    private let settings = NSObject()

    @Test func anotherWindowMinimisingIsNotReported() {
        var reports: [Bool] = []
        let minimising = MainWindowMinimising { reports.append($0) }
        minimising.windowMoved(to: main)

        minimising.handle(NSWindow.didMiniaturizeNotification, object: settings)
        minimising.handle(NSWindow.didDeminiaturizeNotification, object: settings)
        #expect(reports.isEmpty)
    }

    @Test func theMainWindowMinimisingIsReportedBothWays() {
        var reports: [Bool] = []
        let minimising = MainWindowMinimising { reports.append($0) }
        minimising.windowMoved(to: main)

        minimising.handle(NSWindow.didMiniaturizeNotification, object: main)
        minimising.handle(NSWindow.didDeminiaturizeNotification, object: main)
        #expect(reports == [true, false])
    }

    /// Closing and reopening can give the scene a new window, and the old
    /// view's move out (to no window) can arrive after the new view's move
    /// in. A move out must not undo the move in - so it changes nothing, and
    /// a window that goes away clears itself, being held weakly.
    @Test func aViewLeavingItsWindowDoesNotForgetTheMainWindow() {
        var reports: [Bool] = []
        let minimising = MainWindowMinimising { reports.append($0) }
        minimising.windowMoved(to: main)
        minimising.windowMoved(to: nil)

        minimising.handle(NSWindow.didMiniaturizeNotification, object: settings)
        #expect(reports.isEmpty)
    }

    /// Before the main window's view has said which window it is, every
    /// window counts - what the observers did before the filter existed -
    /// rather than minimising being ignored altogether.
    @Test func withNoMainWindowKnownEveryWindowIsReported() {
        var reports: [Bool] = []
        let minimising = MainWindowMinimising { reports.append($0) }

        minimising.handle(NSWindow.didMiniaturizeNotification, object: settings)
        #expect(reports == [true])
    }
}
