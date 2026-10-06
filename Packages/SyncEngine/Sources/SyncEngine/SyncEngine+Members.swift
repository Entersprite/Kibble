import ChatKit
import Foundation

extension SyncEngine {
    /// Asks the backend for a space's members, once per conversation per
    /// session (mention composer spec §3.3). A DM's members come with the
    /// world. Marked before the call so two selections do not both ask, and
    /// unmarked when the call is refused, so the next selection retries.
    func loadMembers(in conversation: Conversation.ID) async {
        guard capabilities.canMention, !membersLoaded.contains(conversation) else { return }
        // Not before the session exists: the backend would refuse, and the
        // refusal showed as a banner on launch (review finding 6). The
        // reconnect catch-up asks again on the first `.connected`.
        guard case .connected = try? store.connectionState() else { return }
        guard let kind = (try? store.conversations())?.first(where: { $0.id == conversation })?.kind,
              kind == .space || kind == .meetChat else { return }
        membersLoaded.insert(conversation)
        if await !submit(.loadMembers(conversationID: conversation)) {
            membersLoaded.remove(conversation)
        }
    }
}
