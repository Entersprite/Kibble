import ChatKit

public extension FakeBackend {
    func starredMessages(after cursor: String?) async throws -> StarredMessagesPage {
        try requireConnected()
        try require(capabilities.canStarMessages, "starredMessages")
        let messages = starredAddresses.compactMap(starTarget)
        let offset = try starredOffset(cursor, count: messages.count)
        let end = min(offset + 30, messages.count)
        let page = Array(messages[offset ..< end])
        let senders = Set(page.map(\.sender))
        let members = world.members.filter { senders.contains($0.id) }
        return StarredMessagesPage(
            messages: page,
            members: members,
            nextCursor: end < messages.count ? String(end) : nil
        )
    }

    func setMessageStarred(_ starred: Bool, at address: MessageAddress) async throws {
        try requireConnected()
        try require(capabilities.canStarMessages, "starredMessages")
        guard starTarget(address) != nil else { throw ChatError.decoding("This message cannot be starred.") }
        starredAddresses.removeAll { $0 == address }
        if starred {
            starredAddresses.insert(address, at: 0)
        }
        emit(.messageStarChanged(address: address, starred: starred))
    }
}

extension FakeBackend {
    private func starredOffset(_ cursor: String?, count: Int) throws -> Int {
        guard let cursor else { return 0 }
        guard let value = Int(cursor), value > 0, value <= count else {
            throw ChatError.decoding("This starred page is unavailable.")
        }
        return value
    }

    private func starTarget(_ address: MessageAddress) -> Message? {
        world.messages(in: address.conversation).first {
            $0.id == address.message && $0.threadID == address.thread && !$0.isDeleted
                && $0.callStatus == nil && $0.activity == nil
        }
    }
}
