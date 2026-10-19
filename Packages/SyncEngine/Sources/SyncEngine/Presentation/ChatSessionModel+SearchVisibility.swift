import ChatKit
import ChatPersistence

extension ChatSessionModel {
    func openNewDirectConversation(with member: Member.ID) {
        searchWork.openTask?.cancel()
        let selection = selected
        searchWork.openTask = Task { @MainActor [weak self, engine] in
            guard let conversation = await engine.openDirectConversation(with: member),
                  !Task.isCancelled, let self, selected == selection else { return }
            openSearchConversation(conversation.id)
        }
    }

    /// Search keeps its own snapshots; prune those when the sidebar changes.
    /// No store reads on the main actor while history pages are being written.
    func reconcileSearchVisibility(previous: [Conversation], current: [Conversation]) {
        let visible = Set(current.map(\.id))
        let removed = Set(previous.map(\.id)).subtracting(visible)
        let cutoffs = Dictionary(uniqueKeysWithValues: current.compactMap { conversation in
            conversation.historyClearedBefore.map { (conversation.id, $0) }
        })
        func allowed(_ message: Message) -> Bool {
            !removed.contains(message.conversationID)
                && cutoffs[message.conversationID].map { message.createdAt > $0 } != false
        }
        var state = search
        state.conversations.removeAll { !visible.contains($0.id) }
        state.hits = state.hits.filter(allowed)
        if var bar = state.bar {
            let opened = bar.hits.indices.contains(bar.index) ? bar.hits[bar.index].id : nil
            bar.hits = bar.hits.filter(allowed)
            if let index = bar.hits.firstIndex(where: { $0.id == opened }) {
                bar.index = index
                state.bar = bar
            } else {
                state.bar = nil
                state.highlight = nil
            }
        }
        search = state
    }
}
