import Foundation

/// Rings while the incoming call panel is up: the ringtone chosen in Settings
/// › Calls, looped without a pause, played by Kibble itself at the output
/// volume, as call apps ring.
@MainActor
final class CallRinger {
    private let player: any RingtonePlaying
    private let ringtone: @MainActor () -> URL?
    private(set) var isRinging = false

    init(
        player: any RingtonePlaying = RingtonePlayer(),
        ringtone: @escaping @MainActor () -> URL? = { Ringtone.bundled }
    ) {
        self.player = player
        self.ringtone = ringtone
    }

    func start() {
        guard !isRinging else { return }
        isRinging = true
        // A chosen file that can no longer be played rings with Kibble's own
        // sound rather than not at all.
        for url in [ringtone(), Ringtone.bundled].compactMap(\.self) {
            do {
                try player.play(url, loops: true)
                return
            } catch {
                continue
            }
        }
    }

    func stop() {
        guard isRinging else { return }
        isRinging = false
        player.stop()
    }

    /// Plays a sound once, as Settings › Calls does on a choice; never over a
    /// ringing call.
    func preview(_ url: URL) {
        guard !isRinging else { return }
        try? player.play(url, loops: false)
    }
}
