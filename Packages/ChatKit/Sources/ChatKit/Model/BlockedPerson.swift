public struct BlockedPerson: Codable, Hashable, Identifiable, Sendable {
    public let id: Member.ID
    public let name: String

    public init(id: Member.ID, name: String) {
        self.id = id
        self.name = name
    }
}

public extension Capabilities {
    var canManageBlockedPeople: Bool {
        extendedFlags.contains("blockedPeople")
    }
}

public extension ChatBackend {
    func blockedPeople() async throws -> [BlockedPerson] {
        throw ChatError.unsupported(capability: "blockedPeople")
    }

    func unblockPerson(_: Member.ID) async throws -> [BlockedPerson] {
        throw ChatError.unsupported(capability: "blockedPeople")
    }
}
