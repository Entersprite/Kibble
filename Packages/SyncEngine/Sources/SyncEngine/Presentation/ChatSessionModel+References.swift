import ChatKit
import Foundation

/// Opening what a quote, a forward or a link points at.
public extension ChatSessionModel {
    /// Opens the addressed message where it lives, as a search hit opens:
    /// its conversation scrolled to it and marked, or its thread for a reply.
    /// An address with no message opens its conversation.
    ///
    /// Nothing happens for a conversation this account does not have, or a
    /// message neither the store nor its thread's listing holds, and nothing
    /// moves once the person has gone to another conversation meanwhile. The
    /// message is found before anything is selected, so a miss leaves the
    /// window as it was.
    func openReferencedMessage(_ address: MessageAddress) {
        guard conversations.contains(where: { $0.id == address.conversation }) else { return }
        referenceWork.openTask?.cancel()
        referenceWork.openTask = nil
        guard let id = address.message else {
            select(address.conversation)
            return
        }
        let conversation = address.conversation
        let origin = selected
        let originGeneration = transcriptWork.generation
        let limit = searchWork.historyPageLimit
        referenceWork.openTask = Task { @MainActor [weak self, engine] in
            let found = try? await engine.referencedMessage(id, thread: address.thread, in: conversation)
            guard !Task.isCancelled, let self, let found, selected == origin,
                  transcriptWork.generation == originGeneration else { return }
            let target = try? await engine.loadHistory(in: conversation, until: found, pageLimit: limit)
            guard !Task.isCancelled, selected == origin,
                  transcriptWork.generation == originGeneration,
                  conversations.contains(where: { $0.id == conversation }), let target else { return }
            if selected != conversation || selectedMeetingSeries != nil {
                select(conversation)
            }
            land(on: target)
            var state = search
            state.highlight = target.message.id
            state.openGeneration += 1
            search = state
        }
    }
}

/// The open in flight. `stop()` cancels it.
struct MessageReferenceWork {
    var openTask: Task<Void, Never>?

    mutating func reset() {
        openTask?.cancel()
        openTask = nil
    }
}
