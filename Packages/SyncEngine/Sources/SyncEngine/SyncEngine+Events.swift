import ChatKit
import ChatPersistence
import Foundation

// MARK: - The loop

extension SyncEngine {
    func handle(_ event: ChatEvent) async {
        switch event {
        case let .conversationRemoved(id, _), let .conversationUnreadMarkChanged(id, _):
            invalidateConversationSnapshot(id)
        default: break
        }
        processActivity(event)
        let reduction = SyncReducer.reduce(event)
        do {
            var restored = false
            if case let .messageReceived(message) = event {
                restored = try store.restoreConversationForArrival(message)
            }
            try store.apply(reduction.writes + meetingMetadataWrites(for: event))
            if restored {
                await perform(.reloadConversations)
            }
            // A pushed world is a world load too: `FakeBackend`'s first
            // connect sends one with no gap (ruling 7).
            if case .conversationsChanged = event {
                worldLoaded()
            }
        } catch {
            record(error)
        }
        for effect in reduction.effects {
            await perform(effect)
        }
    }

    /// Performs what the reducer could not: the I/O behind a gap.
    func perform(_ effect: SyncEffect) async {
        do {
            switch effect {
            case .reloadConversations:
                guard !(backend is any ProjectedChatBackend) else { return }
                let version = conversationMutationVersion
                let conversations = try await backend.loadConversations()
                guard version == conversationMutationVersion else { return }
                try applyConversationSnapshot(conversations)
                worldLoaded(forceMentionBackfill: true)
            case let .reloadMessages(conversation):
                guard !(backend is any ProjectedChatBackend) else { return }
                try await loadMoreMessages(in: conversation)
            case let .announceArrival(message):
                announcer.yield(.arrived(message))
            case let .withdrawAnnouncements(conversation, upTo):
                announcer.yield(.read(conversation, upTo: upTo))
            }
        } catch {
            // The same hole `requestMoreMessages` closes, one effect over:
            // `stop()` cancels the consumer task this runs under (see
            // `start()`), and a gap-fill in flight when that happens can
            // throw a cancellation dressed as any error type - see that
            // function's comment for the full reasoning. `Task.isCancelled`
            // names our own cancellation regardless of shape.
            guard !Task.isCancelled else { return }
            record(error)
        }
    }

    /// Puts a failure where the UI can see it. Typed, not rendered: a client
    /// has to tell "sign in again" from "the network hiccuped".
    ///
    /// `undoing` carries any writes that retract what the failed operation had
    /// already claimed. They go in the **same batch** as the error, because
    /// `apply` is one transaction per batch and a window that saw the error
    /// land before the retraction would draw a banner next to the message it
    /// is about to remove.
    func record(_ error: any Error, undoing writes: [StoreWrite] = []) {
        let chatError = error as? ChatError ?? .unknown(String(describing: error))
        try? store.apply(writes + [.setLastError(chatError)])
    }
}
