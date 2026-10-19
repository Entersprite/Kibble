import Foundation
import GChatBridgeCore

public extension LocalBridgeBackend {
    /// Calls share this account's live cookie jar with Chat. The host supplies
    /// hardware, while provider credentials and transport remain in the bridge.
    func makeAudioCallService(
        store: KeychainCredentialStore,
        expectedSession: StoredSessionSummary,
        mediaFactory: @escaping @MainActor @Sendable () -> any CallMediaEngine
    ) async -> LocalBridgeAudioCallService {
        let trial = MeetDMCallTrial(
            store: store, transport: transport, endpoints: endpoints,
            expectedSession: expectedSession, proof: proof
        )
        await trial.useSharedCredentials(credentials)
        return await LocalBridgeAudioCallService(trial: trial, mediaFactory: mediaFactory)
    }
}

extension MeetDMCallTrial {
    func useSharedCredentials(_ credentials: SessionCredentials) {
        sharedCredentials = credentials
    }
}
