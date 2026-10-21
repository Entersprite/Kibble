import ChatKit
import Foundation
import Testing
@testable import LocalBridgeBackend

@MainActor
struct CallEndReasonTests {
    @Test func nativeTerminalCausesRemainDistinctFromTransportFailures() async throws {
        let setup = try await LocalBridgeAudioCallServiceTests().setup()
        let service = setup.service
        let recipient = AudioCallRecipient(
            conversationID: .init("dm"), memberID: .init("peer"), displayName: "Peer"
        )
        let causes: [(MeetNativeCallEndReason, AudioCallEndReason?)] = [
            (.localEnded, .localEnded), (.ringCancelled, .localEnded),
            (.remoteEnded, .remoteEnded), (.invitationEnded, .remoteEnded), (.declined, .declined),
            (.transportFailed, nil), (.joinFailed, nil), (.accountChanged, nil),
            (.ringingTimedOut, nil), (.deviceEnded, nil)
        ]
        for (native, expected) in causes {
            let call = AudioCallSnapshot(
                id: UUID(),
                recipient: recipient,
                direction: .outgoing,
                phase: .connected
            )
            service.snapshot = call
            service.receiveNative(.ended(native), id: call.id, scope: service.callScope)
            #expect(service.snapshot?.endReason == expected)
        }
        await service.stop()
    }

    @Test func clearingForCleanupIsNotARemoteCancellation() async throws {
        let setup = try await LocalBridgeAudioCallServiceTests().setup()
        let service = setup.service
        for remote in [false, true] {
            service.snapshot = AudioCallSnapshot(id: UUID(), recipient: .init(
                conversationID: .init("dm"), memberID: .init("peer"), displayName: "Peer"
            ), direction: .incoming, phase: .incoming)
            await service.receiveIncoming(remote ? .remoteEnded : .cleared, scope: service.sessionScope)
            #expect(service.snapshot?.phase == .ended)
            #expect(service.snapshot?.endReason == (remote ? .remoteEnded : nil))
        }
        await service.stop()
    }
}
