import Foundation

public extension AppEnvironment {
    /// The way back to sign-in from a launch that failed.
    ///
    /// `.needsSignIn` is otherwise reachable from exactly two inputs - no
    /// stored session, and `ChatError.notAuthenticated`. Everything else lands
    /// in `.failed` and would stay there: a page-shape change
    /// (`findings.md` §18), a client refused as an unsupported browser (where
    /// re-capturing with a different user agent is the actual fix), a stored
    /// session that no longer decodes. Each reproduces on every relaunch, and
    /// the only escape would be deleting a credential by hand - which is not
    /// something this app's intended user can do.
    ///
    /// The reason carried forward is the failure itself, so the capture window
    /// says what went wrong rather than implying the person did something.
    func requestSignIn() {
        guard case let .failed(message) = phase else { return }
        Task { await enterNeedsSignIn(reason: message) }
    }
}
