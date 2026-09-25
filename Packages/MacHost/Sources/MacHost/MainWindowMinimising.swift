import AppKit
import SwiftUI

/// Which window's minimising drives the viewing gate.
///
/// AppKit posts `NSWindow.didMiniaturizeNotification` for every window, and
/// the gate (`AppEnvironment.isViewing`) is about one of them: with the
/// observers unfiltered, minimising any other window would read as the main
/// one leaving the screen. SwiftUI does not document which `NSWindow` a
/// `Window` scene becomes, so rather than match an identifier, the main
/// window's own view says which window it is in (`reportsMainWindow(to:)`).
///
/// **Until it has, every window counts** - what the observers did before this
/// filter existed - so a view that never reports degrades to the old
/// behaviour rather than to minimising being ignored.
@MainActor
final class MainWindowMinimising {
    /// Weak: SwiftUI may give the scene a new `NSWindow` when it is closed and
    /// reopened, and the view reports that one when it moves into it.
    private(set) weak var window: AnyObject?
    private let report: @MainActor (Bool) -> Void

    init(report: @escaping @MainActor (Bool) -> Void) {
        self.report = report
    }

    /// A move into a window names it; a move out (`nil`) changes nothing.
    /// On a close and reopen the old view's move out can arrive after the
    /// new view's move in, and clearing there would forget the window just
    /// named. A window that goes away clears itself, being held weakly.
    func windowMoved(to window: AnyObject?) {
        if let window {
            self.window = window
        }
    }

    func handle(_ name: Notification.Name, object: Any?) {
        if let window {
            guard let object, (object as AnyObject) === window else { return }
        }
        switch name {
        case NSWindow.didMiniaturizeNotification:
            report(true)
        case NSWindow.didDeminiaturizeNotification:
            report(false)
        default:
            break
        }
    }
}

public extension View {
    /// Marks the window this view is in as the main window, for
    /// `MacAppDelegate`'s minimise observers.
    func reportsMainWindow(to delegate: MacAppDelegate) -> some View {
        background(MainWindowReader { delegate.mainWindowMinimising.windowMoved(to: $0) })
    }
}

private struct MainWindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow?) -> Void

    func makeNSView(context _: Context) -> WindowReportingView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: WindowReportingView, context _: Context) {
        view.onWindow = onWindow
    }
}

private final class WindowReportingView: NSView {
    var onWindow: (@MainActor (NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow?(window)
    }
}
