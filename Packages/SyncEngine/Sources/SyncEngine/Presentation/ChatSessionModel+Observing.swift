import ChatKit
import Foundation
import GRDB

// MARK: - Observing the store

/// Moved out of `ChatSessionModel.swift` unchanged when the Mentions list
/// took that file to swiftlint's `file_length` ceiling. `watchers`,
/// `directory` and `lastError` are `internal` there for this file's sake,
/// the same trade `+AutoMarkRead.swift` already made for `conversations`.
extension ChatSessionModel {
    /// Members are read once per conversation change rather than observed:
    /// there is one directory for the whole app, it changes rarely, and an
    /// observation per member would be a lot of machinery for a lookup table.
    public func refreshDirectory() {
        directory = Dictionary(
            uniqueKeysWithValues: ((try? store.members()) ?? []).map { ($0.id, $0) }
        )
    }

    /// Who the local user is, and their own availability (set-your-status
    /// spec §4): both session values about you, observed together.
    func watchSelf() {
        watch(store.observeMe()) { [weak self] in self?.me = $0 }
        watch(store.observeAvailability()) { [weak self] in self?.availability = $0 }
    }

    func watch<Value>(
        _ observation: AsyncValueObservation<Value>,
        _ apply: @escaping @MainActor (Value) -> Void
    ) {
        watchers.append(observe(observation, apply))
    }

    func observe<Value>(
        _ observation: AsyncValueObservation<Value>,
        _ apply: @escaping @MainActor (Value) -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            do {
                for try await value in observation {
                    apply(value)
                    self?.refreshDirectory()
                }
            } catch {
                self?.lastError = error as? ChatError ?? .unknown(String(describing: error))
            }
        }
    }
}
