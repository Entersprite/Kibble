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
    }

    func finishComposerPersistence() async {
        let persistence = composerPersistence
        composerPersistence = nil
        services.closeEmbeddedMedia()
        await persistence?.finish()
        draftSaveFailure = nil
    }
}
