import ChatKit

public extension FakeBackend {
    func blockedPeople() throws -> [BlockedPerson] {
        try requireConnected()
        try require(capabilities.canManageBlockedPeople, "blockedPeople")
        return blockedDirectMembers.sorted { $0.rawValue < $1.rawValue }.map { id in
            BlockedPerson(id: id, name: world.members.first(where: { $0.id == id })?.displayName ?? "")
        }
    }

    func unblockPerson(_ id: Member.ID) throws -> [BlockedPerson] {
        try requireConnected()
        try require(capabilities.canManageBlockedPeople, "blockedPeople")
        blockedDirectMembers.remove(id)
        return try blockedPeople()
    }
}
