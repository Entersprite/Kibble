import ChatKit
import Foundation
import GChatBridgeCore

/// What reporting activity sends (active-presence spec §1). `[Verify]` until
/// the owner's run.
enum ActivityRequests {
    /// purple's shape: the header and `user_state`, nothing else.
    static func heartbeat(active: Bool) -> HeartbeatRequest {
        var request = HeartbeatRequest()
        request.requestHeader = APIRequestHeader.make()
        request.presenceUpdateRequest.userState = active ? .active : .inactive
        return request
    }

    /// Your setting wins (spec §3): nothing active under Away, or Do not
    /// disturb with an end still ahead. Unknown availability reports, as
    /// Automatic does.
    static func reportsActive(under availability: Availability?, now: Date) -> Bool {
        switch availability {
        case .away:
            false
        case let .doNotDisturb(until):
            until <= now
        case .automatic, .unknown, nil:
            true
        }
    }
}
