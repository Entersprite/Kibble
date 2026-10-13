import Foundation

/// Explicit invitation mutations. Opaque invitation metadata remains private
/// to the provider adapter and must never be included in reports.
public enum MeetInvitationWire {
    public static func cancel(id: String) throws -> Data {
        _ = try MeetIncomingInvitation(id: id, clientID: nil)
        return MeetProto.string(1, id)
    }

    public static func decline(_ invitation: MeetIncomingInvitation) throws -> Data {
        guard let clientID = invitation.clientID else { throw MeetCallWire.WireError.invalidIdentifier }
        return MeetProto.string(1, invitation.id) + MeetProto.string(2, clientID)
    }

    /// The browser announces receipt before presenting sources other than2.
    /// TOm.Mo action0 -> wire action1, with client selector2.
    public static func received(_ invitation: MeetIncomingInvitation) throws -> Data {
        try decline(invitation) + MeetProto.number(3, 1) + MeetProto.number(4, 2)
    }

    public static func invitationID(from body: Data) throws -> String {
        let data = try MeetProto.decode(body)
        let id = try MeetProto.text(1, data)
        _ = try MeetIncomingInvitation(id: id, clientID: nil)
        return id
    }
}
