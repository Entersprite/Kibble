import ChatKit
import DesignSystem
import Foundation
import SyncEngine

extension AppEnvironment {
    var scheduledForwardAction: (@MainActor (Message.ID, Conversation.ID, String, Date) async -> Bool)? {
        guard let model = runningModel, model.capabilities.canScheduleForwards else { return nil }
        return { [weak self, weak model] id, destination, comment, time in
            guard let self, let model, runningModel === model else { return false }
            let accepted = await model.scheduleForward(id, to: destination, comment: comment, at: time)
            return runningModel === model && accepted
        }
    }

    func scheduledScene(of model: ChatSessionModel) -> ScheduledMessagesScene {
        let queue = model.schedules
        var scene = ScheduledMessagesScene()
        scene.showingList = queue.showingList
        scene.canScheduleAttachments = model.capabilities.canScheduleAttachments
        scene.messages = queue.messages
        scene.pending = queue.pending
        scene.isLoading = queue.isLoading
        scene.readFailed = queue.readFailed
        scene.hasMore = queue.hasMore
        scene.submissions = Set(queue.submissions.map { ComposerDraftAddress(
            conversation: $0.conversation,
            thread: $0.thread
        ) })
        for (destination, receipt) in queue.receipts {
            let address = ComposerDraftAddress(
                conversation: destination.conversation,
                thread: destination.thread
            )
            scene.receipts[address] = ComposerScheduleReceipt(id: receipt.id, draft: receipt.body)
        }
        return scene
    }

    var scheduledActions: ScheduledMessagesActions? {
        guard let model = runningModel, model.capabilities.canScheduleMessages else { return nil }
        let current: @MainActor () -> ChatSessionModel? = { [weak self, weak model] in
            guard let model, self?.runningModel === model else { return nil }
            return model
        }
        let sendNow: ((ScheduledMessageAddress) -> Void)? = model.capabilities.canSendScheduledMessagesNow
            ? { current()?.sendScheduledMessageNow($0) } : nil
        return ScheduledMessagesActions(
            show: { current()?.showScheduledMessages() },
            refresh: { current()?.refreshScheduledMessages() },
            loadMore: { current()?.loadMoreScheduledMessages() },
            submit: { [weak self] address, body, draft, time in
                guard let model = current() else { return false }
                let destination = MessageAddress(conversation: address.conversation, thread: address.thread)
                let sync = model.capabilities.canScheduleSavedDraft ? self?.composerDraftSynchronization : nil
                return model.scheduleMessage(
                    body, draft: draft, at: time, to: destination,
                    prepareDraft: { [weak sync] in try await sync?.prepareSchedule(draft, at: address) },
                    finishDraft: { [weak sync] in sync?.finishSchedule($0, at: address) },
                    confirmed: { [weak self] in
                        guard let self, current() != nil,
                              composerDrafts[address]?.scheduledComposition == draft else { return }
                        composerDraftSynchronization?.submitted(draft, at: address)
                        preserveComposerDraft(ComposerDraft(), at: address)
                    }
                )
            },
            latestReceipt: { address in
                guard let receipt = current()?.schedules.receipts[
                    MessageAddress(conversation: address.conversation, thread: address.thread)
                ] else { return nil }
                return ComposerScheduleReceipt(id: receipt.id, draft: receipt.body)
            },
            edit: { current()?.editScheduledMessage($0, body: $1, finished: $2) ?? false },
            reschedule: { current()?.rescheduleMessage($0, at: $1, finished: $2) ?? false },
            cancel: { current()?.cancelScheduledMessage($0) },
            sendNow: sendNow
        )
    }
}
