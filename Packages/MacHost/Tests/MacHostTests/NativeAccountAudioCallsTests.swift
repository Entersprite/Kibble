import ChatKit
import Foundation
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

    @MainActor @Test func theAccountAdapterForwardsTheMeetingTitlePreviewPort() async throws {
        let store = KeychainCredentialStore(storage: EmptyCallSecrets(), account: "test")
        let binding = NativeAccountCallBinding()
        let source = LocalBridgeAudioCallService(
            trial: MeetDMCallTrial(store: store), mediaFactory: { binding.makeMedia() }
        )
        let adapter: any MeetingLinkAudioCallService = NativeAccountAudioCalls(
            source: source, binding: binding
        )
        let url = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))

        #expect(adapter.canPreviewMeetingLinks)
        await #expect(throws: ChatError.unsupported(capability: "callSessionNotReady")) {
            try await adapter.previewMeetingTitle(at: url)
        }

        source.beginStopping()
        #expect(!adapter.canPreviewMeetingLinks)
        await #expect(throws: CancellationError.self) {
            try await adapter.previewMeetingTitle(at: url)
        }
    }
}

private struct EmptyCallSecrets: SecretStorage {
    func read(account _: String) -> Data? {
        nil
    }

    func write(_: Data, account _: String) {}
    func delete(account _: String) {}
}
