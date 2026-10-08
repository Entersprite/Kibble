import ChatKit
import Foundation

/// Setting your own status and availability (set-your-status spec §4).
/// Commands, not requests: the answer comes back as events, and a refusal
/// lands in `lastError` through `SyncEngine.submit`. Nothing is shown before
/// the answer, so nothing has to spring back (spec §7).
public extension ChatSessionModel {
    func setStatus(_ status: MemberStatus?) {
        Task { [engine] in
            _ = await engine.submit(.setStatus(status))
        }
    }

    func setAvailability(_ availability: Availability) {
        Task { [engine] in
            _ = await engine.submit(.setAvailability(availability))
        }
    }
}
