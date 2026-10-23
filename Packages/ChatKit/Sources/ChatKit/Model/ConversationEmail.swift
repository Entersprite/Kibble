import Foundation

public struct ConversationEmail: Codable, Hashable, Sendable {
    public var address: String?
    public var deliveryEnabled: Bool?
    public var canGenerate: Bool
    public var canChangeDelivery: Bool
    public var canDelete: Bool

    public init(
        address: String? = nil,
        deliveryEnabled: Bool? = nil,
        canGenerate: Bool = false,
        canChangeDelivery: Bool = false,
        canDelete: Bool = false
    ) {
        self.address = address; self.deliveryEnabled = deliveryEnabled; self.canGenerate = canGenerate
        self.canChangeDelivery = canChangeDelivery; self.canDelete = canDelete
    }

    private enum CodingKeys: String,
        CodingKey { case address, deliveryEnabled, canGenerate, canChangeDelivery, canDelete }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        address = try fields.decodeIfPresent(String.self, forKey: .address)
        deliveryEnabled = try fields.decodeIfPresent(Bool.self, forKey: .deliveryEnabled)
        canGenerate = try fields.decodeIfPresent(Bool.self, forKey: .canGenerate) ?? false
        canChangeDelivery = try fields.decodeIfPresent(Bool.self, forKey: .canChangeDelivery) ?? false
        canDelete = try fields.decodeIfPresent(Bool.self, forKey: .canDelete) ?? false
    }
}
