import ChatKit
import LocalBridgeBackend
import Testing
@testable import MacHost

/// A real account's calls reach the service through this adapter, so it must
/// offer every port the native service has: without them the service reports
/// no Join and no group or space calls, and the window offers neither.
struct NativeAccountAudioCallsTests {
    @Test func theAccountAdapterOffersJoinAndConversationCallsLikeItsSource() {
        #expect(LocalBridgeAudioCallService.self is any ExistingAudioCallService.Type)
        #expect(LocalBridgeAudioCallService.self is any ConversationAudioCallService.Type)
        #expect(NativeAccountAudioCalls.self is any ExistingAudioCallService.Type)
        #expect(NativeAccountAudioCalls.self is any ConversationAudioCallService.Type)
    }
}
