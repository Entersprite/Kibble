import AppKit
import Foundation

/// Rings while the incoming call panel is up: two notes every three seconds,
/// played by Kibble itself at the output volume, as call apps ring.
@MainActor
final class CallRinger {
    static let sound = "Glass"
    private let play: @MainActor () -> Void
    private let interval: Duration
    private let gap: Duration
    private var task: Task<Void, Never>?

    init(
        interval: Duration = .seconds(3), gap: Duration = .milliseconds(350),
        play: @escaping @MainActor () -> Void = CallRinger.playSystemSound
    ) {
        self.interval = interval
        self.gap = gap
        self.play = play
    }

    var isRinging: Bool {
        task != nil
    }

    func start() {
        guard task == nil else { return }
        let play = play, interval = interval, gap = gap
        task = Task { @MainActor in
            while !Task.isCancelled {
                play()
                do { try await Task.sleep(for: gap) } catch { return }
                play()
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// A fresh copy each time, so the second note plays while the first one
    /// is still sounding.
    static func playSystemSound() {
        (NSSound(named: sound)?.copy() as? NSSound)?.play()
    }
}
