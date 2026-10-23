import ChatKit
import Foundation
import Testing
@testable import LocalBridgeBackend

/// The other person's microphone reaches the shared call snapshot, and every
/// path that rebuilds that snapshot keeps it.
@MainActor
struct LocalBridgeRemoteMuteTests {
    private let recipient = AudioCallRecipient(
        conversationID: .init("dm"), memberID: .init("peer"), displayName: "Peer"
    )

    @Test func remoteMuteIsPublishedAndSurvivesNativeStateChanges() async throws {
        let setup = try await LocalBridgeAudioCallServiceTests().setup()
        let service = setup.service
        let call = AudioCallSnapshot(id: UUID(), recipient: recipient, direction: .outgoing, phase: .ringing)
        service.snapshot = call
        let scope = service.callScope
        var events = service.events.makeAsyncIterator()
        service.receiveRemoteMuted(true, id: call.id, scope: scope)
        guard case let .snapshot(published)? = await events.next() else {
            Issue.record("Expected a snapshot"); return
        }
        #expect(published.remoteMuted == true)
        service.receiveNative(.active, id: call.id, scope: scope)
        #expect(service.snapshot?.phase == .connected)
        #expect(service.snapshot?.remoteMuted == true)
        service.receiveNative(.reconnecting, id: call.id, scope: scope)
        #expect(service.snapshot?.remoteMuted == true)
        service.receiveRemoteMuted(nil, id: call.id, scope: scope)
        #expect(service.snapshot?.remoteMuted == nil)
        await service.stop()
    }

    @Test func staleOrFinishedCallsIgnoreARemoteMute() async throws {
        let setup = try await LocalBridgeAudioCallServiceTests().setup()
        let service = setup.service
        let call = AudioCallSnapshot(
            id: UUID(),
            recipient: recipient,
            direction: .outgoing,
            phase: .connected
        )
        service.snapshot = call
        let scope = service.callScope
        service.receiveRemoteMuted(true, id: UUID(), scope: scope)
        service.receiveRemoteMuted(true, id: call.id, scope: UUID())
        #expect(service.snapshot?.remoteMuted == nil)
        // Positive control: the current call and scope do take it.
        service.receiveRemoteMuted(false, id: call.id, scope: scope)
        #expect(service.snapshot?.remoteMuted == false)
        service.receiveNative(.ended(.remoteEnded), id: call.id, scope: scope)
        service.receiveRemoteMuted(true, id: call.id, scope: scope)
        #expect(service.snapshot?.phase == .ended)
        #expect(service.snapshot?.remoteMuted == false)
        await service.stop()
    }

    @Test func ownMuteKeepsTheRemoteMicrophoneAndTheSessionReachesTheSnapshot() async throws {
        let fixtures = LocalBridgeAudioCallServiceTests()
        let setup = try await fixtures.setup(fixtures.nativeResponses(outgoing: true))
        try await setup.service.startListening()
        let id = UUID()
        try await setup.service.startOutgoing(to: fixtures.recipient(setup), callID: id)
        let session = try #require(await setup.service.trial.native)
        await session.publishRemoteAudio(true)
        #expect(setup.service.snapshot?.remoteMuted == true)
        try await setup.service.setMuted(true, callID: id)
        #expect(setup.service.snapshot?.isMuted == true)
        #expect(setup.service.snapshot?.remoteMuted == true)
        try await setup.service.setMuted(false, callID: id)
        #expect(setup.service.snapshot?.remoteMuted == true)
        try await setup.service.hangUp(callID: id)
        #expect(setup.service.snapshot?.phase == .ended)
        await setup.service.stop()
    }
}
