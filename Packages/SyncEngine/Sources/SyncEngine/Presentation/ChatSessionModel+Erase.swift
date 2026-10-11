import Foundation

/// Sign-out's erase, beside `stop()` in `ChatSessionModel.swift`; split out
/// to keep that file under swiftlint's `file_length` ceiling.
public extension ChatSessionModel {
    /// Stops the sync loop and erases the database behind it - in that
    /// order, and inside one call, so the order is not something a caller has
    /// to get right by its own timing.
    ///
    /// `stop()` already documents that it *awaits* its consuming task rather
    /// than merely cancelling it, so "no further event can reach the store"
    /// is true the instant it returns - which is exactly the guarantee
    /// erasing needs. Calling these two out of order, or from two separate
    /// `await`s a future edit could interleave, would let a write already in
    /// flight from this very session land after the tables are wiped and
    /// repopulate them.
    ///
    /// Used by `AppEnvironment.signOut()`, which explains what "sign out"
    /// does and does not mean.
    func stopAndEraseStore() async throws {
        await stop()
        try store.erase()
    }
}
