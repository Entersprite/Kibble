import SyncEngine

/// What the window should be showing right now.
///
/// A phase rather than a pair of booleans because the states are genuinely
/// exclusive and the pair-of-booleans version has two unrepresentable
/// combinations - "signed out and running" and "loading and failed" - that a
/// view would have to decide between arbitrarily.
///
/// `needsSignIn` carries an optional reason so that "you have never signed in"
/// and "your session stopped working" reach the same screen with different
/// words. The distinction matters: one is a first run and the other is a
/// nine-day `COMPASS` fuse burning out (`findings.md` §17.2), and telling a
/// person the second is the first invites them to wonder what they did wrong.
@MainActor
enum LaunchPhase {
    case loading
    case needsSignIn(reason: String?)
    case running(ChatSessionModel)
    case failed(String)

    /// A diagnostic run finished and this is its text - `--probe=keychain` and
    /// `--probe=api`.
    ///
    /// Separate from `failed` rather than folded into it, because the two want
    /// different affordances: a failed launch offers a way back to sign-in, and
    /// a finished probe must not, since nothing about it says the session is
    /// bad. The probes previously touched no phase at all, so the window sat on
    /// `loading`'s spinner for ever while the report went only to a file.
    case report(String)
}
