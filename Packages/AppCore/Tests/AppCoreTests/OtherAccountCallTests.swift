import ChatKit
import Foundation
import Testing
@testable import AppCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct OtherAccountCallTests {
    @Test(arguments: [false, true])
    func answeringWaitsForConfirmedCleanupAndDoesNotProceedOnFailure(fail: Bool) async throws {
        let peer = Member(id: .init("peer"), kind: .human)
        let me = Member.ID("self")
        let dm = Conversation(id: .init("dm"), kind: .directMessage, members: [me, peer.id])
        let recipient = AudioCallRecipient(conversationID: dm.id, memberID: peer.id, displayName: "Alex")
        let outgoingSource = RecordingAudioService(recipient: recipient)
        let incomingSource = RecordingAudioService(recipient: recipient)
        let outgoing = AudioCallController(); let incoming = AudioCallController()
        outgoing.start(service: outgoingSource); incoming.start(service: incomingSource)
        try await wait { outgoing.canCall(conversation: dm, members: [peer], me: me) }
        let outgoingID = try #require(outgoing.startCall(in: dm, members: [peer], me: me))
        outgoingSource.emit(.init(
            id: outgoingID,
            recipient: recipient,
            direction: .outgoing,
            phase: .connected
        ))
        let ring = incomingSource.snapshot(phase: .incoming, direction: .incoming)
        incomingSource.emit(ring)
        try await wait { incoming.call?.phase == .incoming && outgoing.call?.phase == .connected }
        outgoingSource.suspendHangUp = true; outgoingSource.hangUpFailure = fail
        let answer = Task { await incoming.accept(ending: outgoing) }
        do {
            try await wait { outgoingSource.hangUpContinuation != nil }
            #expect(incomingSource.operations.isEmpty)
            outgoingSource.hangUpContinuation?.resume(); outgoingSource.hangUpContinuation = nil
            await answer.value
            #expect(incomingSource.operations == (fail ? [] : ["accept"]))
            if fail {
                #expect(incoming.call?.phase == .incoming)
                #expect(incoming.call?.failureMessage != nil)
            }
        } catch {
            outgoingSource.hangUpContinuation?.resume(); outgoingSource.hangUpContinuation = nil
            await answer.value
            await outgoing.stop(); await incoming.stop()
            throw error
        }
        await outgoing.stop(); await incoming.stop()
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 1000 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(condition())
    }
}
