import Foundation

/// Ephemeral receiver metadata. Never persisted or included in diagnostics.
public struct MeetIncomingInvitation: Sendable, CustomStringConvertible {
    public let id: String
    public let clientID: String?

    public init(id: String, clientID: String?) throws {
        guard Self.valid(id), clientID.map(Self.valid) ?? true else {
            throw MeetCallWire.WireError.invalidIdentifier
        }
        self.id = id
        self.clientID = clientID
    }

    public var description: String {
        "MeetIncomingInvitation(values withheld)"
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && value.utf8.allSatisfy { (33 ... 126).contains($0) }
    }
}
