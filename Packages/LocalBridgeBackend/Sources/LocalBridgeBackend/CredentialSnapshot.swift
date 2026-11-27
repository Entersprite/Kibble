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
    let calendarSession: StoredSession?

    private enum CodingKeys: String,
        CodingKey { case custodyGeneration, custodyIdentity, custodySourceGeneration, calendarSession }

    init(
        session: StoredSession,
        generation: String?,
        verifiedIdentity: String? = nil,
        sourceGeneration: String? = nil, calendarSession: StoredSession? = nil
    ) {
        self.session = session
        self.generation = generation
        self.verifiedIdentity = verifiedIdentity
        self.sourceGeneration = sourceGeneration
        self.calendarSession = calendarSession
    }

    init(from decoder: any Decoder) throws {
        session = try StoredSession(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        generation = try values.decodeIfPresent(String.self, forKey: .custodyGeneration)
        verifiedIdentity = try values.decodeIfPresent(String.self, forKey: .custodyIdentity)
        sourceGeneration = try values.decodeIfPresent(String.self, forKey: .custodySourceGeneration)
        calendarSession = try values.decodeIfPresent(StoredSession.self, forKey: .calendarSession)
    }

    func encode(to encoder: any Encoder) throws {
        try session.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(generation, forKey: .custodyGeneration)
        try values.encodeIfPresent(verifiedIdentity, forKey: .custodyIdentity)
        try values.encodeIfPresent(sourceGeneration, forKey: .custodySourceGeneration)
        try values.encodeIfPresent(calendarSession, forKey: .calendarSession)
    }

    func matches(_ other: CredentialSnapshot) -> Bool {
        generation == other.generation && session.capturedAt == other.session.capturedAt &&
            session.expiresAt == other.session.expiresAt
    }

    func replacingCookies(_ cookies: SessionCookies) -> CredentialSnapshot {
        CredentialSnapshot(
            session: StoredSession(
                credential: cookies, capturedAt: session.capturedAt, expiresAt: session.expiresAt
            ),
            generation: generation,
            verifiedIdentity: verifiedIdentity,
            sourceGeneration: sourceGeneration,
            calendarSession: calendarSession
        )
    }

    func installingCalendar(_ calendar: StoredSession) -> CredentialSnapshot {
        CredentialSnapshot(
            session: session, generation: generation, verifiedIdentity: verifiedIdentity,
            sourceGeneration: sourceGeneration, calendarSession: calendar
        )
    }
}
