import Foundation
@testable import SyncEngine

/// The engine's first announcement, or `nil` after a second - so a missing
/// one fails rather than hangs. Cancelling the loser finishes the engine's
/// stream for good (`CLAUDE.md`, §25.10's rule), which is harmless for an
/// engine the calling test throws away.
func firstAnnouncement(of engine: SyncEngine) async -> SyncAnnouncement? {
    await withTaskGroup(of: SyncAnnouncement?.self) { group in
        group.addTask { await engine.announcements.first { _ in true } }
        group.addTask {
            try? await Task.sleep(for: .seconds(1))
            return nil
        }
        // `group.next()` is `SyncAnnouncement??` - the group's own optional
        // around each task's - and `flatMap` flattens the two.
        let first = await group.next().flatMap(\.self)
        group.cancelAll()
        return first
    }
}
