import Foundation

/// Request outcomes without account IDs, payloads, or raw error text.
public struct ConversationActionObservation: Codable, Sendable, Equatable {
    public let rpc: String
    public let status: Int?
    public let serviceCode: Int?
    public let outcome: String
    public let payloadShape: String?
    public let hasSessionProof: Bool?

    public init(
        rpc: String,
        status: Int?,
        serviceCode: Int?,
        outcome: String,
        payloadShape: String? = nil,
        hasSessionProof: Bool? = nil
    ) {
        self.rpc = rpc
        self.status = status
        self.serviceCode = serviceCode
        self.outcome = outcome
        self.payloadShape = payloadShape
        self.hasSessionProof = hasSessionProof
    }
}

public extension LocalBridgeBackend {
    func observeConversationActions(_ callback: @escaping @Sendable (ConversationActionObservation) -> Void) {
        onConversationAction = callback
    }
}
