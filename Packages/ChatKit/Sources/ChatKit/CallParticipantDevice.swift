import Foundation

/// Ephemeral, call-local device identity. It is never a provider resource or a
/// fabricated directory member. A presentation can name its parent device.
public struct CallParticipantDevice: Codable, Hashable, Sendable {
    public let id: UUID
    public let displayName: String?
    public let parentID: UUID?
    public let isPresentation: Bool
    public let isLocal: Bool
    public let microphoneMuted: Bool?

    public init(
        id: UUID, displayName: String? = nil, parentID: UUID? = nil,
        isPresentation: Bool = false, isLocal: Bool = false, microphoneMuted: Bool? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.parentID = parentID
        self.isPresentation = isPresentation
        self.isLocal = isLocal
        self.microphoneMuted = microphoneMuted
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, parentID, isPresentation, isLocal, microphoneMuted
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: fields.decode(UUID.self, forKey: .id),
            displayName: fields.decodeIfPresent(String.self, forKey: .displayName),
            parentID: fields.decodeIfPresent(UUID.self, forKey: .parentID),
            isPresentation: fields.decodeIfPresent(Bool.self, forKey: .isPresentation) ?? false,
            isLocal: fields.decodeIfPresent(Bool.self, forKey: .isLocal) ?? false,
            microphoneMuted: try? fields.decodeIfPresent(Bool.self, forKey: .microphoneMuted)
        )
    }
}
