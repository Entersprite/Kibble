import ChatKit
import Foundation

/// Account-owned presentation audio. Repeated snapshots and reconnects do not
/// replay participant cues, and local teardown never masquerades as remote hangup.
@MainActor
final class CallSoundFeedback {
    private let setLoop: (AppSound?) -> Void
    private let play: ([AppSound]) -> Void
    private let stopPlayback: () -> Void
    private var callID: UUID?
    private var loop: AppSound?
    private var joined = false
    private var locallyEnded = false
    private var reportedEnd = false
    private var incomingWasAudible = false
    private var participating = false
    private var connectingPlayed = false
    private var connectingCueActive = false

    convenience init() {
        var loopPlayer: RingtonePlayer?
        var cuePlayer: RingtonePlayer?
        self.init(setLoop: { sound in
            loopPlayer?.stop()
            guard let url = sound?.url else { loopPlayer = nil; return }
            let player = loopPlayer ?? RingtonePlayer()
            loopPlayer = player
            try? player.play(url, loops: true)
        }, play: { sounds in
            let urls = sounds.compactMap(\.url)
            guard !urls.isEmpty else { return }
            let player = cuePlayer ?? RingtonePlayer()
            cuePlayer = player
            try? player.play(urls)
        }, stop: {
            loopPlayer?.stop()
            cuePlayer?.stop()
            loopPlayer = nil
            cuePlayer = nil
        })
    }

    init(
        setLoop: @escaping (AppSound?) -> Void,
        play: @escaping ([AppSound]) -> Void,
        stop: @escaping () -> Void
    ) {
        self.setLoop = setLoop; self.play = play; stopPlayback = stop
    }

    func update(call: AudioCallSnapshot?, isEnding: Bool, incomingRings: Bool = false) {
        guard let call else { stop(); return }
        if callID != call.id {
            stop()
            callID = call.id
        }
        locallyEnded = locallyEnded || isEnding
        recordEngagement(call, incomingRings: incomingRings)
        updateConnectingCue(call, isEnding: isEnding)
        let nextLoop = loopSound(for: call, isEnding: isEnding)
        if nextLoop != loop {
            loop = nextLoop
            setLoop(nextLoop)
        }
        if call.phase == .connected, !joined, !locallyEnded {
            joined = true
            play([.personJoined])
        }
        reportEnd(call)
    }

    private func updateConnectingCue(_ call: AudioCallSnapshot, isEnding: Bool) {
        if connectingCueActive, call.phase != .connecting || isEnding {
            stopPlayback()
            connectingCueActive = false
            loop = nil
        }
        guard call.phase == .connecting, !isEnding, !locallyEnded,
              !joined, !connectingPlayed else { return }
        connectingPlayed = true
        connectingCueActive = true
        play([.connecting])
    }

    private func recordEngagement(_ call: AudioCallSnapshot, incomingRings: Bool) {
        if call.phase == .incoming {
            incomingWasAudible = incomingRings
        }
        if call.phase == .connecting || call.phase == .connected {
            participating = true
        }
    }

    private func reportEnd(_ call: AudioCallSnapshot) {
        guard call.phase.isTerminal, !locallyEnded, !reportedEnd else { return }
        // A muted or Focus-suppressed invitation must not make a sound when it ends.
        if call.direction == .incoming, !participating, !incomingWasAudible {
            return
        }
        switch call.endReason {
        case .remoteEnded, .declined:
            reportedEnd = true
            play(joined ? [.personLeft] : [.hangup])
        default: break
        }
    }

    private func loopSound(for call: AudioCallSnapshot, isEnding: Bool) -> AppSound? {
        guard !isEnding, !joined else { return nil }
        return switch call.phase {
        case .ringing where call.direction == .outgoing: .ringing
        default: nil
        }
    }

    func stop() {
        stopPlayback()
        callID = nil; loop = nil; joined = false; locallyEnded = false; reportedEnd = false
        incomingWasAudible = false; participating = false
        connectingPlayed = false; connectingCueActive = false
    }
}
