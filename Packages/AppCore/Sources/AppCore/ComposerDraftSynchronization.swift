import ChatKit
import DesignSystem
import Foundation
import Observation

/// One account's remote drafts and the local versions currently being worked on.
@MainActor
@Observable
final class ComposerDraftSynchronization {
    @MainActor
    private final class Entry {
        var local: ComposedMessage?
        var remote: SyncedDraft?
        var hasRead = false
        var dirty: Bool
        var submitted = false
        var scheduling = false
        var refreshRequested = false
        var status = ComposerDraftSyncStatus()
        var read: Task<Void, Never>?
        var delay: Task<Void, Never>?
        var write: Task<Void, Never>?
        var attempt: (change: SyncedDraftChange, id: String)?

        init(_ local: ComposedMessage?) {
            self.local = local
            dirty = local != nil
        }
    }

    private(set) var statuses: [ComposerDraftAddress: ComposerDraftSyncStatus] = [:]
    @ObservationIgnored private var entries: [ComposerDraftAddress: Entry] = [:]
    @ObservationIgnored private var closed = false
    private let connected: () -> Bool
    private let writable: Bool
    private let debounce: Duration
    private let fetch: (ComposerDraftAddress) async throws -> SyncedDraft?
    private let save: (SyncedDraftChange, String) async throws -> SyncedDraftWriteResult

    init(
        connected: @escaping () -> Bool, writable: Bool, debounce: Duration = .milliseconds(750),
        fetch: @escaping (ComposerDraftAddress) async throws -> SyncedDraft?,
        save: @escaping (SyncedDraftChange, String) async throws -> SyncedDraftWriteResult
    ) {
        self.connected = connected
        self.writable = writable
        self.debounce = debounce
        self.fetch = fetch
        self.save = save
    }

    func opened(_ address: ComposerDraftAddress, local: ComposedMessage?) {
        guard !closed else { return }
        let entry = entry(at: address, initial: local)
        refresh(entry, at: address)
    }

    func invalidated(_ address: ComposerDraftAddress, local: ComposedMessage?) {
        guard !closed else { return }
        let entry = entry(at: address, initial: local)
        entry.refreshRequested = true
        if entry.status.replacement != nil {
            entry.status.replacement = nil
            publish(entry, at: address)
        }
        refresh(entry, at: address)
    }

    func observed(_ local: ComposedMessage?, at address: ComposerDraftAddress) {
        guard !closed else { return }
        let entry = entry(at: address, initial: nil)
        guard entry.local != local else { return }
        entry.local = local
        entry.dirty = true
        if entry.submitted {
            guard local != nil else { return }
            entry.submitted = false
            entry.hasRead = false
        }
        if entry.status.replacement != nil {
            entry.status.replacement = nil
            entry.status.conflict = local != entry.remote?.body
            entry.dirty = entry.status.conflict
            publish(entry, at: address)
        }
        if entry.hasRead {
            enqueue(entry, at: address)
        } else {
            refresh(entry, at: address)
        }
    }

    /// An optimistic send clears the local field before the provider confirms delivery.
    func submitted(_ body: ComposedMessage?, at address: ComposerDraftAddress) {
        guard !closed else { return }
        let entry = entry(at: address, initial: body)
        entry.submitted = true
        entry.local = nil
        entry.dirty = false
        entry.delay?.cancel()
        entry.delay = nil
        entry.status = ComposerDraftSyncStatus()
        publish(entry, at: address)
    }

    func beginSend(_ body: ComposedMessage, at address: ComposerDraftAddress) -> SyncedDraft? {
        let entry = entries[address]
        let candidate: SyncedDraft? = if let entry, entry.local == body, entry.hasRead,
                                         !entry.submitted, !entry.scheduling, entry.write == nil,
                                         !entry.status.conflict, entry.status.replacement == nil,
                                         entry.remote?.canRestore == true {
            entry.remote
        } else {
            nil
        }
        let conflict = entry?.status.conflict == true ? entry?.status : nil
        submitted(body, at: address)
        if let entry, let conflict {
            entry.submitted = false
            entry.status = conflict
            entry.status.replacement = nil
            publish(entry, at: address)
        }
        return candidate
    }

    func finishSend(_ consumed: SyncedDraft?, at address: ComposerDraftAddress) {
        guard let entry = entries[address] else { return }
        if let consumed, entry.remote == consumed {
            entry.remote = nil
            entry.hasRead = true
            entry.submitted = false
            entry.attempt = nil
        }
        refresh(entry, at: address)
    }

    func prepareSchedule(
        _ body: ComposedMessage,
        at address: ComposerDraftAddress
    ) async throws -> SyncedDraft? {
        guard !closed else { throw CancellationError() }
        let entry = entry(at: address, initial: body)
        if !entry.hasRead {
            refresh(entry, at: address)
        }
        entry.scheduling = true
        entry.delay?.cancel()
        entry.delay = nil
        await entry.read?.value
        await entry.write?.value
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard entry.local == body, !entry.submitted, !entry.status.conflict,
              entry.status.replacement == nil, entry.remote?.canRestore == true else { return nil }
        return entry.remote
    }

    func finishSchedule(_ converted: SyncedDraft?, at address: ComposerDraftAddress) {
        guard let entry = entries[address], entry.scheduling else { return }
        entry.scheduling = false
        if let converted, entry.remote?.id == converted.id {
            entry.remote = nil
            entry.hasRead = false
            entry.attempt = nil
        }
        if entry.refreshRequested || (!entry.submitted && entry.local != nil) {
            refresh(entry, at: address)
        }
    }

    func useSaved(at address: ComposerDraftAddress) {
        guard let entry = entries[address], entry.status.conflict,
              entry.remote?.canRestore != false else { return }
        offer(entry, at: address)
    }

    func keepLocal(at address: ComposerDraftAddress) {
        guard writable, let entry = entries[address], entry.status.conflict,
              entry.remote?.canRestore != false else { return }
        entry.status.replacement = nil
        entry.status.conflict = false
        entry.dirty = true
        publish(entry, at: address)
        enqueue(entry, at: address)
    }

    func resolved(_ id: UUID, at address: ComposerDraftAddress, local: ComposedMessage?, applied: Bool) {
        guard let entry = entries[address], entry.status.replacement?.id == id else { return }
        entry.local = local
        entry.dirty = !applied && local != entry.remote?.body
        entry.status.replacement = nil
        entry.status.conflict = entry.dirty
        publish(entry, at: address)
    }

    func stop() async {
        closed = true
        let work = entries.values.flatMap { [$0.read, $0.delay, $0.write].compactMap(\.self) }
        entries = [:]
        statuses = [:]
        work.forEach { $0.cancel() }
        for task in work {
            await task.value
        }
    }
}

extension ComposerDraftSynchronization {
    private func entry(at address: ComposerDraftAddress, initial: ComposedMessage?) -> Entry {
        if let existing = entries[address] {
            return existing
        }
        let entry = Entry(initial)
        entries[address] = entry
        return entry
    }

    private func refresh(_ entry: Entry, at address: ComposerDraftAddress) {
        guard connected(), !entry.scheduling, entry.read == nil, entry.write == nil else { return }
        entry.delay?.cancel()
        entry.delay = nil
        entry.refreshRequested = false
        entry.read = Task { [weak self, weak entry] in
            guard let self, let entry else { return }
            do {
                let draft = try await fetch(address)
                entry.read = nil
                guard !Task.isCancelled, !closed else { return }
                if entry.refreshRequested {
                    refresh(entry, at: address)
                } else {
                    received(draft, entry: entry, at: address)
                }
            } catch {
                entry.read = nil
                guard !Task.isCancelled, !closed else { return }
                fail(entry, at: address)
                if entry.refreshRequested {
                    refresh(entry, at: address)
                }
            }
        }
    }

    private func received(_ draft: SyncedDraft?, entry: Entry, at address: ComposerDraftAddress) {
        let previous = entry.remote
        let changed = entry.hasRead ? entry.remote != draft : draft != nil
        entry.hasRead = true
        entry.remote = draft
        entry.status.failed = false
        if entry.submitted {
            guard previous != nil, changed else { return }
            entry.submitted = false
        }
        entry.status.unsupportedContent = draft?.canRestore == false
        if entry.status.unsupportedContent {
            entry.status.conflict = true
        } else if entry.local == draft?.body {
            entry.dirty = false
            entry.attempt = nil
            entry.status.conflict = false
        } else if !entry.dirty {
            offer(entry, at: address)
            return
        } else if changed {
            entry.status.conflict = true
        }
        publish(entry, at: address)
        enqueue(entry, at: address)
    }

    private func offer(_ entry: Entry, at address: ComposerDraftAddress) {
        entry.status.replacement = ComposerDraftReplacement(
            id: UUID(), expected: entry.local, body: entry.remote?.body
        )
        publish(entry, at: address)
    }

    private func enqueue(_ entry: Entry, at address: ComposerDraftAddress) {
        entry.delay?.cancel()
        entry.delay = nil
        if entry.refreshRequested {
            refresh(entry, at: address)
            return
        }
        guard writable, connected(), entry.hasRead, entry.dirty, !entry.submitted, !entry.scheduling,
              entry.read == nil, entry.write == nil,
              !entry.status.conflict, entry.status.replacement == nil, !entry.status.failed else { return }
        entry.delay = Task { [weak self, weak entry, debounce] in
            do { try await Task.sleep(for: debounce) } catch { return }
            guard let self, let entry, !closed, connected() else { return }
            entry.delay = nil
            startWrite(entry, at: address)
        }
    }

    private func startWrite(_ entry: Entry, at address: ComposerDraftAddress) {
        guard entry.local != nil || entry.remote != nil else { return }
        let change = SyncedDraftChange(address: address, previous: entry.remote, body: entry.local)
        let id = entry.attempt.flatMap { $0.change == change ? $0.id : nil } ?? ClientOperationID.make()
        entry.attempt = (change, id)
        entry.write = Task { [weak self, weak entry] in
            guard let self, let entry else { return }
            do {
                let result = try await save(change, id)
                entry.write = nil
                guard !Task.isCancelled, !closed else { return }
                accepted(result, change: change, entry: entry, at: address)
            } catch {
                entry.write = nil
                guard !Task.isCancelled, !closed else { return }
                fail(entry, at: address)
                if entry.refreshRequested {
                    refresh(entry, at: address)
                }
            }
        }
    }

    private func accepted(
        _ result: SyncedDraftWriteResult, change: SyncedDraftChange, entry: Entry,
        at address: ComposerDraftAddress
    ) {
        entry.attempt = nil
        entry.remote = result.current
        guard !entry.submitted else {
            if entry.refreshRequested {
                refresh(entry, at: address)
            }
            return
        }
        entry.status.unsupportedContent = result.current?.canRestore == false
        entry.status.conflict = !result.applied || (change.body == nil && result.current != nil)
        entry.dirty = entry.status.conflict || entry.local != change.body
        publish(entry, at: address)
        if entry.hasRead {
            enqueue(entry, at: address)
        } else {
            refresh(entry, at: address)
        }
    }

    private func fail(_ entry: Entry, at address: ComposerDraftAddress) {
        guard !Task.isCancelled, !closed, !entry.submitted else { return }
        entry.status.failed = true
        publish(entry, at: address)
    }

    private func publish(_ entry: Entry, at address: ComposerDraftAddress) {
        var value = entry.status
        value.savedDraftWasCleared = value.conflict && entry.remote == nil
        statuses[address] = value == ComposerDraftSyncStatus() ? nil : value
    }
}
