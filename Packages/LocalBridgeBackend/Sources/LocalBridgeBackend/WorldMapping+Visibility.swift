import GChatBridgeCore

extension WorldMapping {
    static func isVisible(_ item: WorldItemLite) -> Bool {
        let state = item.readState
        if state.blocked {
            return false
        }
        if state.hasMembershipState, state.membershipState == .memberNotAMember {
            return false
        }
        if state.hasVisibleInWorldView {
            return state.visibleInWorldView
        }
        return state.hideTimestamp <= 0 || (item.hasSortTimestamp && item.sortTimestamp > state.hideTimestamp)
    }
}
