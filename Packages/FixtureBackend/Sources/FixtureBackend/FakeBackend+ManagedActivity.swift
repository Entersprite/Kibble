import ChatKit

extension FakeBackend: ManagedChatActivityBackend {
    /// The fixture emits scripted activity directly and has no polling resource.
    public func setReceiveInterests(
        presenceMembers: Set<Member.ID>, conversations: Set<Conversation.ID>
    ) {}
}
