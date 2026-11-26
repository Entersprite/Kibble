import ChatKit

extension FakeBackend: CallDiscoveryBackend {
    public func callAvailability(in id: Conversation.ID) throws -> ConversationCallAvailability {
        try requireConnected()
        guard capabilities.canDiscoverCalls else { throw ChatError.unsupported(capability: "callDiscovery") }
        guard world.conversations.contains(where: { $0.id == id }), !hiddenConversations.contains(id) else {
            throw ChatError.unknown("The conversation is unavailable.")
        }
        guard let value = callAvailability[id] else {
            return .init(conversationID: id, status: .unknown("unavailable"), checkedAt: now)
        }
        return .init(
            conversationID: id, status: value.status, checkedAt: now,
            reference: value.reference, joinURL: value.joinURL,
            participantsChangedAt: value.participantsChangedAt,
            participants: value.participants, totalParticipants: value.totalParticipants
        )
    }

    /// A scenario supplies live state explicitly; transcript cards never infer it.
    public func setCallAvailability(_ value: ConversationCallAvailability) {
        callAvailability[value.conversationID] = value
    }
}
