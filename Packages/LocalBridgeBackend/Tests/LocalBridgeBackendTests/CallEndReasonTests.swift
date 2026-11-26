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
            (.ringingTimedOut, nil), (.deviceEnded, nil), (.removedFromMeeting, .removedFromMeeting),
            (.switchedDevice, .switchedDevice), (.conferenceEnded, .conferenceEnded)
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

    @Test(arguments: [true, false])
    func incompatibleClientExplainsTheCallEnd(cleanupUnconfirmed: Bool) async throws {
        let setup = try await LocalBridgeAudioCallServiceTests().setup()
        let service = setup.service
        let link = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
        let target = ConversationCallTarget(meetingURL: link, displayName: "Meeting")
        let call = ConversationCallSnapshot(id: UUID(), target: target, phase: .connected)
        service.conversationSnapshot = call
        var cleanup = MeetNativeCallCleanup()
        cleanup.leaveUnconfirmed = cleanupUnconfirmed
        let terminal: MeetNativeCallState = cleanupUnconfirmed
            ? .endedUnconfirmed(.incompatibleClient, cleanup) : .ended(.incompatibleClient)
        service.receiveNative(terminal, id: call.id, scope: service.callScope)
        let result = try #require(service.conversationSnapshot)
        let message = try #require(result.failureMessage)
        #expect(result.phase == .ended)
        #expect(result.endReason == nil)
        #expect(message.contains("Open the meeting in your browser."))
        #expect(message.contains("hasn't confirmed") == cleanupUnconfirmed)
        await service.stop()
    }
}
