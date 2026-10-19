import ChatKit
import ChatPersistence
import Foundation

extension SyncEngine {
    /// A bounded, read-only server check for cached roots inside the page's
    /// time span. Topic windows can overlap or move when a reply arrives, so
    /// only a complete direct thread listing authorizes removing a row.
    func verifyMissingRoots(in conversation: Conversation.ID, against page: [Message]) async {
        let roots = page.filter { !$0.isReply }
        guard roots.count > 1,
              let oldest = roots.map(\.createdAt).min(),
              let newest = roots.map(\.createdAt).max() else { return }
        let excluded = checkedMissingRoots.union(roots.map(\.id))
        guard let candidates = try? store.cachedMissingRootCandidates(
            in: conversation, from: oldest, through: newest, excluding: excluded
        ) else { return }
        for message in candidates {
            guard !Task.isCancelled else { return }
            do {
                let snapshot = try await backend.loadThreadSnapshot(message.threadID, in: conversation)
                try Task.checkCancellation()
                guard snapshot.isComplete,
                      snapshot.messages.allSatisfy({ $0.conversationID == conversation
                              && $0.threadID == message.threadID }) else { continue }
                if !snapshot.messages.contains(where: { $0.id == message.id }) {
                    try store.apply([.removeMessage(id: message.id)])
                }
                checkedMissingRoots.insert(message.id)
            } catch {
                // A refused verification proves nothing about the cached row.
                // The ordinary history page has already loaded successfully.
                continue
            }
        }
    }
}
