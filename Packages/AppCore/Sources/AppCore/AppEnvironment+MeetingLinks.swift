import DesignSystem
import SyncEngine

extension AppEnvironment {
    /// Return to Call for this session's own call, Join only on a fresh
    /// observation of one going on, otherwise Call where the service can.
    func callOffer(in model: ChatSessionModel) -> ConversationCallOffer? {
        guard let id = model.selected,
              let conversation = model.conversations.first(where: { $0.id == id }) else { return nil }
        return ConversationCallOffer.resolve(
            inCall: calls.activeConversationID == id,
            observedActive: calls.discovery.isActive(in: id),
            canJoin: calls.canJoin(conversation: conversation, directory: model.directory, me: model.me),
            canCall: calls.canCall(conversation: conversation, directory: model.directory, me: model.me),
            participants: calls.discovery.participantCount(in: id)
        )
    }

    func installMeetingLinkAction(in actions: inout ChatSceneActions) {
        guard calls.canJoinMeetingLinks else { return }
        let calls = calls
        actions.joinMeeting = { [weak calls] in calls?.prepareMeeting(at: $0) }
    }
}
