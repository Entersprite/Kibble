@preconcurrency import AVFoundation
import CoreAudio
import Foundation

@MainActor
protocol CallSpeakerPlayback: AnyObject {
    func play(device uid: String, completion: @escaping (Bool) -> Void) throws
    func stop()
}

@MainActor
final class NativeCallSpeakerPlayback: NSObject, CallSpeakerPlayback, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var onEnd: ((Bool) -> Void)?

    static func defaultOutput() -> String? {
        try? AudioHardwareSystem.shared.defaultOutputDevice?.uid
    }

    func play(device uid: String, completion: @escaping (Bool) -> Void) throws {
        stop()
        guard let url = Ringtone.bundled,
              let device = try AudioHardwareSystem.shared.device(forUID: uid),
              try device.streams.contains(where: { try $0.direction == .output })
        else { throw PlaybackFailure.unavailable }
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.currentDevice = uid
        guard player.currentDevice == uid, player.play() else { throw PlaybackFailure.unavailable }
        self.player = player
        onEnd = completion
    }

    func stop() {
        player?.delegate = nil
        player?.stop()
        player = nil
        onEnd = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finished(PlayerIdentity(player: player), success: flag)
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        finished(PlayerIdentity(player: player), success: false)
    }

    private nonisolated func finished(_ source: PlayerIdentity, success: Bool) {
        Task { @MainActor [weak self] in
            guard let self, player === source.player else { return }
            let completion = onEnd
            stop()
            completion?(success)
        }
    }

    /// Retains the exact object until the delegate result is checked on the main actor.
    private struct PlayerIdentity: @unchecked Sendable {
        let player: AVAudioPlayer
    }

    private enum PlaybackFailure: Error {
        case unavailable
    }
}
