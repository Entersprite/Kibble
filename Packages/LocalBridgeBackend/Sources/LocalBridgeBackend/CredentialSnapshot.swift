import Foundation
import GChatBridgeCore

public enum SessionCustodyError: Error, Sendable, Equatable {
    case sessionChanged
    case occupied
}

/// The added root key is ignored by older StoredSession decoders. A legacy
/// credential without that key remains readable until its next fresh capture.
struct CredentialSnapshot: Codable, Sendable {
    let session: StoredSession
    let generation: String?
    let verifiedIdentity: String?
    let sourceGeneration: String?

    private enum CodingKeys: String,
        CodingKey { case custodyGeneration, custodyIdentity, custodySourceGeneration }

    init(
        session: StoredSession,
        generation: String?,
        verifiedIdentity: String? = nil,
        sourceGeneration: String? = nil
    ) {
        self.session = session
        self.generation = generation
        self.verifiedIdentity = verifiedIdentity
        self.sourceGeneration = sourceGeneration
    }

    init(from decoder: any Decoder) throws {
        session = try StoredSession(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        generation = try values.decodeIfPresent(String.self, forKey: .custodyGeneration)
        verifiedIdentity = try values.decodeIfPresent(String.self, forKey: .custodyIdentity)
        sourceGeneration = try values.decodeIfPresent(String.self, forKey: .custodySourceGeneration)
    }

    func encode(to encoder: any Encoder) throws {
        try session.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(generation, forKey: .custodyGeneration)
        try values.encodeIfPresent(verifiedIdentity, forKey: .custodyIdentity)
        try values.encodeIfPresent(sourceGeneration, forKey: .custodySourceGeneration)
    }

    func matches(_ other: CredentialSnapshot) -> Bool {
        generation == other.generation && session.capturedAt == other.session.capturedAt &&
            session.expiresAt == other.session.expiresAt
    }

    func replacingCookies(_ cookies: SessionCookies) -> CredentialSnapshot {
        CredentialSnapshot(session: StoredSession(
            credential: cookies, capturedAt: session.capturedAt, expiresAt: session.expiresAt
        ), generation: generation, verifiedIdentity: verifiedIdentity, sourceGeneration: sourceGeneration)
    }
}
