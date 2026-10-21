import ChatKit
import Foundation
import Testing
@testable import MacHost

@MainActor
struct CallSoundFeedbackTests {
    private func call(_ phase: AudioCallPhase = .connecting) -> AudioCallSnapshot {
        AudioCallSnapshot(id: UUID(), recipient: .init(
            conversationID: .init("dm"), memberID: .init("peer"), displayName: "Peer"
        ), direction: .outgoing, phase: phase)
    }

    @Test func connectingPlaysOnceAndOnlyRingingLoopsBeforeTheJoinedCue() {
        let log = SoundLog()
        let feedback = log.feedback()
        var call = call()
        feedback.update(call: call, isEnding: false)
        feedback.update(call: call, isEnding: false)
        call.phase = .ringing
        feedback.update(call: call, isEnding: false)
        call.phase = .connected
        feedback.update(call: call, isEnding: false)
        feedback.update(call: call, isEnding: false)
        #expect(log.loops == [.ringing, nil])
        #expect(log.cues == [[.connecting], [.personJoined]])
        // A connection interruption/recovery is not a participant leaving/rejoining.
        call.phase = .connecting
        feedback.update(call: call, isEnding: false)
        call.phase = .connected
        feedback.update(call: call, isEnding: false)
        #expect(log.loops.count == 2)
        #expect(log.cues == [[.connecting], [.personJoined]])
        call.phase = .ended; call.endReason = .remoteEnded
        feedback.update(call: call, isEnding: false)
        feedback.update(call: call, isEnding: false)
        #expect(log.cues == [[.connecting], [.personJoined], [.personLeft]])
    }

    @Test func remoteCancellationAndRejectionPlayHangupWithoutAParticipantLeaving() {
        for reason in [AudioCallEndReason.remoteEnded, .declined] {
            let log = SoundLog()
            let feedback = log.feedback()
            var call = call(.ringing)
            feedback.update(call: call, isEnding: false)
            call.phase = .ended; call.endReason = reason
            feedback.update(call: call, isEnding: false)
            #expect(log.loops == [.ringing, nil])
            #expect(log.cues == [[.hangup]])
        }
    }

    @Test func aSilentIncomingInvitationRemainsSilentWhenTheCallerCancels() {
        for rings in [false, true] {
            let log = SoundLog()
            let feedback = log.feedback()
            var call = call(.incoming)
            call = AudioCallSnapshot(
                id: call.id,
                recipient: call.recipient,
                direction: .incoming,
                phase: .incoming
            )
            feedback.update(call: call, isEnding: false, incomingRings: rings)
            call.phase = .ended; call.endReason = .remoteEnded
            feedback.update(call: call, isEnding: false)
            #expect(log.cues == (rings ? [[.hangup]] : []))
        }
    }

    @Test func localEndingFailuresAndSilentTeardownDoNotClaimRemoteDeparture() {
        let log = SoundLog()
        let feedback = log.feedback()
        var call = call()
        feedback.update(call: call, isEnding: false)
        feedback.update(call: call, isEnding: true)
        #expect(log.loops.isEmpty)
        call.phase = .ended; call.endReason = .remoteEnded
        feedback.update(call: call, isEnding: false)
        #expect(log.cues == [[.connecting]])
        var failed = self.call(.ringing)
        feedback.update(call: failed, isEnding: false)
        failed.phase = .failed
        feedback.update(call: failed, isEnding: false)
        #expect(log.cues == [[.connecting]])
        feedback.update(call: self.call(), isEnding: false)
        let stops = log.stops
        feedback.update(call: nil, isEnding: false)
        #expect(log.stops == stops + 1)
        #expect(log.cues == [[.connecting], [.connecting]])
    }

    @Test func accountsOwnTheirAudioIndependentlyAndLateTerminalCausePlaysOnlyOnce() {
        let first = SoundLog(); let second = SoundLog()
        let firstFeedback = first.feedback(); let secondFeedback = second.feedback()
        var call = call()
        firstFeedback.update(call: call, isEnding: false)
        secondFeedback.update(call: call, isEnding: false)
        firstFeedback.stop()
        #expect(second.stops == 1)
        call.phase = .ended
        secondFeedback.update(call: call, isEnding: false)
        #expect(second.cues == [[.connecting]])
        call.endReason = .remoteEnded
        secondFeedback.update(call: call, isEnding: false)
        secondFeedback.update(call: call, isEnding: false)
        #expect(second.cues == [[.connecting], [.hangup]])
    }
}

@MainActor
private final class SoundLog {
    var loops: [AppSound?] = []
    var cues: [[AppSound]] = []
    var stops = 0
    func feedback() -> CallSoundFeedback {
        CallSoundFeedback(
            setLoop: { self.loops.append($0) },
            play: { self.cues.append($0) },
            stop: { self.stops += 1 }
        )
    }
}
