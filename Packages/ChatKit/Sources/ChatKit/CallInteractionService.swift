import Foundation

/// Ephemeral capabilities of the joined call. The link is public metadata,
/// never a meeting credential or a grant to another account.
public struct CallInteractionState: Codable, Hashable, Sendable {
    public var activities: CallActivitiesState?
    public var joinURL: URL?
    public var canRaiseHand: Bool
    public var canInvite: Bool

    public init(joinURL: URL? = nil, canRaiseHand: Bool = false, canInvite: Bool = false) {
        self.joinURL = joinURL
        self.canRaiseHand = canRaiseHand
        self.canInvite = canInvite
    }

    private enum CodingKeys: String, CodingKey { case joinURL, canRaiseHand, canInvite, activities }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        activities = try fields.decodeIfPresent(CallActivitiesState.self, forKey: .activities)
        joinURL = try fields.decodeIfPresent(URL.self, forKey: .joinURL)
        canRaiseHand = try fields.decodeIfPresent(Bool.self, forKey: .canRaiseHand) ?? false
        canInvite = try fields.decodeIfPresent(Bool.self, forKey: .canInvite) ?? false
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
