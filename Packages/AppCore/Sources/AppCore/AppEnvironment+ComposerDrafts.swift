import ChatKit
import DesignSystem
import Foundation
import SyncEngine

extension AppEnvironment {
    func loadComposerDrafts(store: ChatStore) async throws {
        let persistence = ComposerPersistence(store: store, saved: { [weak self] in
            self?.draftSaveFailure = nil
        }, failure: { [weak self] _ in
            self?.draftSaveFailure = .unknown(
                "Draft could not be saved. Keep this window open and try again."
            )
        })
        composerPersistence = persistence
        let saved = try await persistence.load()
        try Task.checkCancellation()
        composerDrafts = Dictionary(saved.map {
            (
                ComposerDraftAddress(conversation: $0.conversation, thread: $0.thread),
                ComposerDraft(snapshot: $0)
            )
        }, uniquingKeysWith: { _, latest in latest })
    }

    func preserveComposerDraft(_ draft: ComposerDraft, at address: ComposerDraftAddress) {
        guard case .running = phase, composerPersistence != nil else { return }
        let composition = draft.compositionOnly
        composerDrafts[address] = composition.text.isEmpty && composition.quote == nil ? nil : composition
        composerPersistence?.save(composerDrafts.map { $0.value.snapshot(at: $0.key) })
        composerDraftSynchronization?.observed(composition.syncedComposition, at: address)
    }

    func startComposerDraftSynchronization(for model: ChatSessionModel) {
        guard model.capabilities.canReadSyncedDrafts else { return }
        let synchronization = ComposerDraftSynchronization(
            connected: { [weak model] in model?.canSyncComposerDrafts == true },
            writable: model.capabilities.canWriteSyncedDrafts,
            fetch: { [weak model] address in
                guard let model else { throw CancellationError() }
                return try await model.syncedComposerDraft(at: address)
            },
            save: { [weak model] change, operationID in
                guard let model else { throw CancellationError() }
                return try await model.writeComposerDraft(change, operationID: operationID)
            }
        )
        composerDraftSynchronization = synchronization
        model.refreshOpenDraft = { [weak self, weak synchronization] address in
            guard let self, let synchronization,
                  composerDraftSynchronization === synchronization else { return }
            synchronization.invalidated(address, local: composerDrafts[address]?.syncedComposition)
        }
    }

    var composerDraftSyncActions: ((ComposerDraftAddress) -> ComposerDraftSync?)? {
        guard let model = runningModel, let sync = composerDraftSynchronization else { return nil }
        let statuses = sync.statuses
        let connected = model.canSyncComposerDrafts
        let writable = model.capabilities.canWriteSyncedDrafts
        return { [weak self, weak model, weak sync] address in
            guard let self, let model, let sync, composerDraftSynchronization === sync else { return nil }
            let submit = syncedDraftSubmission(in: model, synchronization: sync, at: address)
            return ComposerDraftSync(
                connected: connected,
                status: statuses[address] ?? ComposerDraftSyncStatus(),
                opened: { [weak self, weak sync] in
                    guard let self, let sync, composerDraftSynchronization === sync else { return }
                    sync.opened(address, local: composerDrafts[address]?.syncedComposition)
                },
                resolved: { [weak sync] in sync?.resolved($0, at: address, local: $1, applied: $2) },
                useSaved: { [weak sync] in sync?.useSaved(at: address) },
                keepLocal: writable ? { [weak sync] in sync?.keepLocal(at: address) } : nil,
                submitted: { [weak sync] in sync?.submitted($0, at: address) },
                send: submit.map { submit in { submit($0, $1, nil) } },
                addAndSend: model.capabilities.canMentionNonMembers ? submit : nil,
                isCurrentOffer: { [weak sync] in sync?.statuses[address]?.replacement?.id == $0 }
            )
        }
    }

    private func syncedDraftSubmission(
        in model: ChatSessionModel, synchronization: ComposerDraftSynchronization,
        at address: ComposerDraftAddress
    ) -> ((ComposedMessage, ComposedMessage, [Member.ID]?) -> Void)? {
        guard model.capabilities.canSendSavedDraft else { return nil }
        return { [weak self, weak model, weak synchronization] message, local, people in
            guard let model, let synchronization, self?.runningModel === model,
                  self?.composerDraftSynchronization === synchronization else { return }
            let draft = synchronization.beginSend(local, at: address)
            let completed: @MainActor (Bool) -> Void = { [weak synchronization] consumed in
                synchronization?.finishSend(consumed ? draft : nil, at: address)
            }
            if let people {
                model.addAndSend(message, adding: people, at: address, consuming: draft, completed: completed)
            } else if let thread = address.thread {
                model.sendReply(
                    message,
                    in: address.conversation,
                    thread: thread,
                    consuming: draft,
                    completed: completed
                )
            } else {
                model.send(message, in: address.conversation, consuming: draft, completed: completed)
            }
        }
    }

    func finishComposerPersistence() async {
        let persistence = composerPersistence
        let synchronization = composerDraftSynchronization
        composerPersistence = nil
        composerDraftSynchronization = nil
        services.closeEmbeddedMedia()
        await synchronization?.stop()
        await persistence?.finish()
        draftSaveFailure = nil
    }
}

private extension ChatSessionModel {
    var canSyncComposerDrafts: Bool {
        connectionState == .connected && isClientTransportAvailable
    }
}
