import Foundation

/// The window's half of the viewing gate - see `isViewing`.
///
/// Both are reported by the host, which is the only layer that knows a window
/// exists: the app shell's `.onAppear`/`.onDisappear` for open, `MacHost`'s
/// `NSWindow` observers for minimised, since a minimised window's views do not
/// disappear. Like `setActive(_:)`, both are held while no model exists and
/// applied the moment one is built.
public extension AppEnvironment {
    /// A window that appears is not minimised. Closing a minimised window
    /// reports no deminiaturise, so without this the flag - and the gate with
    /// it - would stay off for every window after.
    func setWindowOpen(_ open: Bool) {
        windowOpen = open
        if open {
            windowMinimized = false
        }
        applyViewing()
    }

    func setWindowMinimized(_ minimized: Bool) {
        windowMinimized = minimized
        applyViewing()
    }
}

extension AppEnvironment {
    /// Whether the user can see the window: frontmost, open and not minimised.
    ///
    /// **One value for two consumers, so they cannot drift.** Automatic
    /// mark-as-read publishes only while this is true, and a notification is
    /// suppressed as "on screen" only while it is true. Before it existed the
    /// model was told frontmost alone, from a `.task` on the window's own view
    /// - so closing the window cancelled the only thing reporting focus, left
    /// the value frozen at `true`, and read receipts could be published for a
    /// conversation nobody could see. Unknown frontmost reads as `true`, the
    /// model's own default, which `pendingActive`'s doc comment explains.
    var isViewing: Bool {
        (pendingActive ?? true) && windowOpen && !windowMinimized
    }

    func applyViewing() {
        model?.setActive(isViewing)
    }
}
