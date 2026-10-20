import ChatKit
import Foundation

/// Complete ephemeral state for the authenticated device, independent of chat replay.
public struct ServiceCallState: Codable, Hashable, Sendable {
    public var version: String
    public var isListening: Bool
    public var recipients: [AudioCallRecipient]
    public var call: AudioCallSnapshot?
    public var lastEvent: AudioCallEvent?

    public init(
        version: String, isListening: Bool = false, recipients: [AudioCallRecipient] = [],
        call: AudioCallSnapshot? = nil, lastEvent: AudioCallEvent? = nil
    ) {
        self.version = version; self.isListening = isListening; self.recipients = recipients
        self.call = call; self.lastEvent = lastEvent
    }
}

/// A bounded long poll. The device comes from trusted transport context.
public struct ReadCallState: ServiceRequestPayload {
    public typealias Response = ServiceCallState
    public static let operation = "readCallState"
    public static let requiresAccount = true
    public let after: String?
    public let waitMilliseconds: Int

    public init(after: String? = nil, waitMilliseconds: Int = 20000) {
        self.after = after; self.waitMilliseconds = waitMilliseconds
    }
}

/// Call control is ephemeral and never replayed from the durable chat ledger.
/// Unknown actions are refused. Reusing a start callID cannot ring twice.
public struct ControlCall: ServiceRequestPayload {
    public typealias Response = ServiceCallState
    public static let operation = "controlCall"
    public static let requiresAccount = true
    public let action: String
    public let callID: UUID?
    public let recipient: AudioCallRecipient?
    public let muted: Bool?

    public init(
        action: String, callID: UUID? = nil, recipient: AudioCallRecipient? = nil, muted: Bool? = nil
    ) {
        self.action = action; self.callID = callID; self.recipient = recipient; self.muted = muted
    }
}
