import Foundation

/// Ephemeral call details and capabilities. The URL carries public meeting metadata.
public struct CallInteractionState: Codable, Hashable, Sendable {
    public var activities: CallActivitiesState?
    public var joinURL: URL?
    public var dialIn: CallDialIn?
    public var alternateDialIns: [CallDialIn]?
    public var dialInNumbersURL: URL?
    public var canRaiseHand: Bool
    public var canInvite: Bool

    public init(joinURL: URL? = nil, canRaiseHand: Bool = false, canInvite: Bool = false) {
        self.joinURL = joinURL
        self.canRaiseHand = canRaiseHand
        self.canInvite = canInvite
    }

    private enum CodingKeys: String, CodingKey {
        case joinURL, dialIn, alternateDialIns, dialInNumbersURL, canRaiseHand, canInvite, activities
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        activities = try fields.decodeIfPresent(CallActivitiesState.self, forKey: .activities)
        joinURL = try fields.decodeIfPresent(URL.self, forKey: .joinURL)
        dialIn = try fields.decodeIfPresent(CallDialIn.self, forKey: .dialIn)
        alternateDialIns = try fields.decodeIfPresent([CallDialIn].self, forKey: .alternateDialIns)
        dialInNumbersURL = try fields.decodeIfPresent(URL.self, forKey: .dialInNumbersURL)
        canRaiseHand = try fields.decodeIfPresent(Bool.self, forKey: .canRaiseHand) ?? false
        canInvite = try fields.decodeIfPresent(Bool.self, forKey: .canInvite) ?? false
    }
}

/// Shareable meeting details, scoped to the current call and kept in memory.
public struct CallDialIn: Codable, Hashable, Sendable {
    public let phoneNumber: String
    public let pin: String
    public let regionCode: String?

    public init(phoneNumber: String, pin: String, regionCode: String? = nil) {
        self.phoneNumber = phoneNumber
        self.pin = pin
        self.regionCode = regionCode
    }
}

@MainActor
public protocol CallInteractionService: AudioCallService {
    func setHandRaised(_ raised: Bool, callID: UUID) async throws
    func inviteToCall(_ member: Member.ID, callID: UUID) async throws
}

public extension CallInteractionService {
    func inviteToCall(_: Member.ID, callID _: UUID) async throws {
        throw ChatError.unsupported(capability: "callInvitations")
    }
}
