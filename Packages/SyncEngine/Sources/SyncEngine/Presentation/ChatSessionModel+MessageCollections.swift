import ChatKit

extension ChatSessionModel {
    func watchMessageCollectionChanges() {
        guard capabilities.canReadSyncedDrafts || capabilities.canScheduleMessages
            || capabilities.canStarMessages || capabilities.canReadConversationSections
        else { return }
        watchers.append(Task { @MainActor [weak self, engine] in
            for await change in engine.messageCollectionChanges {
                guard let self, !Task.isCancelled else { return }
                await applyMessageCollectionChange(change)
            }
        })
    }

    private func applyMessageCollectionChange(_ change: MessageCollectionChange) async {
        switch change {
        case let .unsent(unsent):
            applyUnsentMessageChange(unsent)
        case let .star(address, starred):
            guard capabilities.canStarMessages else { return }
            stars.setKnownStar(starred, at: address)
            refreshStarredMessages()
        case .refreshAll:
            applyUnsentMessageChange(.init(address: nil, drafts: true, scheduled: true))
            refreshStarredMessages()
            await refreshChangedConversationSections()
        case .conversationSections:
            await refreshChangedConversationSections()
        }
    }

    private func applyUnsentMessageChange(_ change: UnsentMessagesChange) {
        if change.scheduled {
            invalidateScheduledMessages()
        }
        guard change.drafts, capabilities.canReadSyncedDrafts, let selected else { return }
        let main = ComposerDraftAddress(conversation: selected)
        if change.address == nil || change.address == main {
            refreshOpenDraft?(main)
        }
        if isThreadPanelShown, let openThread = threads.openThread {
            let reply = ComposerDraftAddress(conversation: selected, thread: openThread)
            if change.address == nil || change.address == reply {
                refreshOpenDraft?(reply)
            }
        }
    }
}
