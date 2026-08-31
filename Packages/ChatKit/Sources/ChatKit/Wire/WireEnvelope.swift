import Foundation

/// The version of the frame format this build speaks.
public enum WireSchema {
    /// Starts at 1. Bump it only for a change a reader cannot detect on its
    /// own — an unknown discriminator or an unknown enum string is already
    /// handled by every decoder here without a version bump, which is the
    /// whole reason those exist.
    public static let currentVersion = 1
}

/// What actually goes on a wire: a version, and one frame.
///
/// The version lives outside the payload deliberately. A reader must be able to
/// tell "I cannot parse this at all" from "I do not recognise this event",
/// and the second case must not require the first machinery.
///
/// Decoding does **not** reject an unfamiliar `schemaVersion`. A frame from a
/// version 2 server is very likely still readable — that is what the `.unknown`
/// cases are for — so the choice of whether to trust it belongs to the caller,
/// which can compare against `WireSchema.currentVersion`.
public struct WireEnvelope<Payload: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var payload: Payload

    public init(payload: Payload, schemaVersion: Int = WireSchema.currentVersion) {
        self.schemaVersion = schemaVersion
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case payload
    }
}

/// Events travel from backend to client.
public typealias EventEnvelope = WireEnvelope<ChatEvent>

/// Commands travel from client to backend.
public typealias CommandEnvelope = WireEnvelope<ChatCommand>
