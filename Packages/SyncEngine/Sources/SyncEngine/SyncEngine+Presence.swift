import ChatKit
import Foundation

public extension SyncEngine {
    /// Names `conversation`'s stored senders to the backend as on screen, so
    /// their presence is asked about now rather than never.
    ///
    /// A backend learns of senders only on pages it fetched this session,
    /// while the transcript shows every stored message - including ones kept
    /// from earlier launches, whose senders' names are already known and so
    /// are never looked up again. Without this, their avatars had no dot.
    ///
    /// **A hint, so it never records an error.** It is not `submit(_:)`: a
    /// backend that is not connected refuses it, and the model sends it
    /// again when the connection comes back. A banner for that would be
    /// noise about something that fixes itself.
    func watchPresence(in conversation: Conversation.ID) async {
        guard let people = try? store.presenceCandidates(in: conversation), !people.isEmpty else { return }
        try? await backend.send(.watchPresence(members: people))
    }
}
