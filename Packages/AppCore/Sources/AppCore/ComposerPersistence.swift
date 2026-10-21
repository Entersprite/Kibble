import ChatKit
import Foundation
import SyncEngine

/// Blocking replica work runs away from the main actor. One write is in
/// flight and one complete replacement may wait; typing cannot grow a queue.
private actor ComposerStorage {
    let store: ChatStore

    init(_ store: ChatStore) {
        self.store = store
    }

    func load() throws -> [ComposerSnapshot] {
        try store.composerDrafts()
    }

    func save(_ snapshot: [ComposerSnapshot]) throws {
        try store.saveComposerDrafts(snapshot)
    }
}

@MainActor
final class ComposerPersistence {
    private let storage: ComposerStorage
    private var pending: [ComposerSnapshot]?
    private var task: Task<Void, Never>?
    private var closed = false
    private let saved: @MainActor () -> Void
    private let failure: @MainActor (Error) async -> Void

    init(
        store: ChatStore, saved: @escaping @MainActor () -> Void = {},
        failure: @escaping @MainActor (Error) async -> Void
    ) {
        storage = ComposerStorage(store)
        self.saved = saved
        self.failure = failure
    }

    func load() async throws -> [ComposerSnapshot] {
        try await storage.load()
    }

    func save(_ snapshot: [ComposerSnapshot]) {
        guard !closed else { return }
        pending = snapshot
        guard task == nil else { return }
        task = Task {
            while let snapshot = pending {
                pending = nil
                do {
                    try await storage.save(snapshot)
                    saved()
                } catch {
                    await failure(error)
                }
            }
            task = nil
        }
    }

    /// Close admission before awaiting, then drain before store erasure.
    func finish() async {
        closed = true
        await task?.value
    }
}
