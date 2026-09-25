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
        minimising.window = main

        minimising.handle(NSWindow.didMiniaturizeNotification, object: settings)
        minimising.handle(NSWindow.didDeminiaturizeNotification, object: settings)
        #expect(reports.isEmpty)
    }

    @Test func theMainWindowMinimisingIsReportedBothWays() {
        var reports: [Bool] = []
        let minimising = MainWindowMinimising { reports.append($0) }
        minimising.window = main

        minimising.handle(NSWindow.didMiniaturizeNotification, object: main)
        minimising.handle(NSWindow.didDeminiaturizeNotification, object: main)
        #expect(reports == [true, false])
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
