import Foundation

/// The window's half of the viewing gate - see `isViewing`.
///
/// Both are reported by the host, which is the only layer that knows a window
/// exists: the app shell's `.onAppear`/`.onDisappear` for open, `MacHost`'s
/// `NSWindow` observers for minimised, since a minimised window's views do not
/// disappear. Like `setActive(_:)`, both are held while no model exists and
/// applied the moment one is built.
public extension AppEnvironment {
    func setWindowOpen(_ open: Bool) {
        windowOpen = open
        applyViewing()
    }

    func setWindowMinimized(_ minimized: Bool) {
        windowMinimized = minimized
        applyViewing()
    }
}
