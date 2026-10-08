import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `heartbeat`'s body (active-presence spec §1). `[Verify]` until the
/// owner's run: purple's shape, never sent from Kibble.
struct ActivityRequestsTests {
    @Test func activeSaysActive() {
        let request = ActivityRequests.heartbeat(active: true)
        #expect(request.hasRequestHeader)
        #expect(request.presenceUpdateRequest.userState == .active)
    }

    @Test func inactiveSaysInactive() {
        let request = ActivityRequests.heartbeat(active: false)
        #expect(request.presenceUpdateRequest.hasUserState)
        #expect(request.presenceUpdateRequest.userState == .inactive)
    }

    /// purple sets nothing else, and neither does this.
    @Test func darkLaunchIsLeftUnset() {
        #expect(!ActivityRequests.heartbeat(active: true).presenceUpdateRequest.hasDarkLaunch)
    }
}
