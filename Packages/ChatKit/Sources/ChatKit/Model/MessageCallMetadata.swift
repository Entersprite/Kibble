import Foundation

/// Historical provider metadata. A reference or link does not establish that
/// the call is active, that this account may join, or that media is connected.
public struct MessageCallMetadata: Codable, Hashable, Sendable {
    /// Opaque within the provider/account. Clients only hold and return it.
    public var reference: String?
    public var joinURL: URL?
    public var endedAt: Date?
    public var participantsChangedAt: Date?

    public init(
        reference: String? = nil, joinURL: URL? = nil,
        endedAt: Date? = nil, participantsChangedAt: Date? = nil
    ) {
        self.reference = reference
        self.joinURL = joinURL
        self.endedAt = endedAt
        self.participantsChangedAt = participantsChangedAt
    }

    public var isEmpty: Bool {
        reference == nil && joinURL == nil && endedAt == nil && participantsChangedAt == nil
    }

    private enum CodingKeys: String, CodingKey {
        case reference, joinURL, endedAt, participantsChangedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            reference: container.decodeIfPresent(String.self, forKey: .reference),
            joinURL: container.decodeIfPresent(URL.self, forKey: .joinURL),
            endedAt: container.decodeWireIfPresent(Date.self, forKey: .endedAt),
            participantsChangedAt: container.decodeWireIfPresent(Date.self, forKey: .participantsChangedAt)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(reference, forKey: .reference)
        try container.encodeIfPresent(joinURL, forKey: .joinURL)
        try container.encodeWireIfPresent(endedAt, forKey: .endedAt)
        try container.encodeWireIfPresent(participantsChangedAt, forKey: .participantsChangedAt)
    }
}
