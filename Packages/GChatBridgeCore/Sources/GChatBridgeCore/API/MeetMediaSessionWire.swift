import Foundation

/// Media sessions use structured protobuf configuration, not a string-valued
/// SDP RPC. The native offer/answer converter must supply this schema.
public enum MeetMediaSessionWire {
    public struct Session: Sendable {
        public let name: String
        public let serverConfiguration: Data
    }

    /// Source: FH field 3 is client config; csf field 1 is the MediaSession.
    public static func create(clientConfiguration: Data) throws -> Data {
        try MeetProto.validate(clientConfiguration)
        guard !clientConfiguration.isEmpty, clientConfiguration.count <= 500_000 else {
            throw MeetCallWire.WireError.invalidIdentifier
        }
        return MeetProto.bytes(1, MeetProto.bytes(3, clientConfiguration))
    }

    /// Response field 2 is server config. Field 3 echoes the submitted client
    /// config and must never be mistaken for the remote configuration.
    public static func session(from body: Data) throws -> Session {
        let data = try MeetProto.decode(body)
        let name = try MeetProto.text(1, data)
        guard MeetDeviceWire.validMediaSession(name) else { throw MeetCallWire.WireError.malformedResponse }
        let configuration = try MeetProto.payload(2, data)
        try MeetProto.validate(configuration)
        guard !configuration.isEmpty else { throw MeetCallWire.WireError.malformedResponse }
        return Session(name: name, serverConfiguration: configuration)
    }
}
