import DesignSystem
import Foundation
import Observation

@MainActor
protocol CallPreparationAudioRoute: AnyObject {
    func authorizeMicrophone() async -> Bool
    func startMicrophone(device uid: String) async -> Bool
    var microphoneLevel: Double? { get }
    func stopMicrophone() -> Task<Void, Never>
    func playSpeaker(device uid: String, completion: @escaping (Bool) -> Void) throws
    func stopSpeaker()
}

@MainActor
@Observable
final class CallPreparationAudio {
    private(set) var microphone = CallPreparationAudioChecks.Microphone.off
    private(set) var isPlaying = false
    private(set) var notice: String?
    @ObservationIgnored private var meeting: UUID?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored private var route: (any CallPreparationAudioRoute)?
    @ObservationIgnored private var microphoneStarted = false
    @ObservationIgnored private var microphoneDevice: String?
    @ObservationIgnored private var speakerDevice: String?
    @ObservationIgnored private let makeRoute: () -> any CallPreparationAudioRoute

    init(makeRoute: @escaping () -> any CallPreparationAudioRoute = { NativePreparationAudio() }) {
        self.makeRoute = makeRoute
    }

    func bind(_ meeting: UUID?) {
        guard self.meeting != meeting else { return }
        stop()
        self.meeting = meeting
        notice = nil
    }

    func configure(microphone: String?, speaker: String?) {
        if (self.microphone != .off && microphoneDevice != microphone)
            || (isPlaying && speakerDevice != speaker) {
            stop()
        }
        microphoneDevice = microphone
        speakerDevice = speaker
    }

    func toggleMicrophone(in id: UUID, allowed: @escaping @MainActor () -> Bool) {
        guard meeting == id, let device = microphoneDevice, allowed() else { return }
        let shouldStart = microphone == .off
        stop()
        guard shouldStart else { return }
        notice = nil
        let route = makeRoute()
        self.route = route
        microphone = .starting
        let revision = revision
        operation = Task { [weak self] in
            guard self?.revision == revision else { return }
            let authorized = await route.authorizeMicrophone()
            await self?.runMicrophone(
                route,
                device: device,
                revision: revision,
                authorized: authorized,
                allowed: allowed
            )
        }
    }

    private func runMicrophone(
        _ route: any CallPreparationAudioRoute, device: String, revision: Int,
        authorized: Bool, allowed: @escaping @MainActor () -> Bool
    ) async {
        guard self.revision == revision else { return }
        guard authorized else { fail("Microphone access is off."); return }
        await cleanup?.value
        guard self.revision == revision else { return }
        guard allowed() else { stop(); return }
        microphoneStarted = true
        let started = await route.startMicrophone(device: device)
        guard self.revision == revision else { return }
        guard started else { fail("Couldn’t start the microphone test."); return }
        operation = Task { [weak self] in
            while !Task.isCancelled, self?.showLevel(from: route, allowed: allowed) == true {
                try? await Task.sleep(for: .milliseconds(125))
            }
        }
    }

    private func showLevel(
        from route: any CallPreparationAudioRoute,
        allowed: @MainActor () -> Bool
    ) -> Bool {
        guard allowed() else { stop(); return false }
        guard let level = route.microphoneLevel else {
            fail("Microphone test stopped.")
            return false
        }
        if microphone != .active(level) {
            microphone = .active(level)
        }
        return true
    }

    func toggleSpeaker(in id: UUID, allowed: @escaping @MainActor () -> Bool) {
        guard meeting == id, let device = speakerDevice, allowed() else { return }
        let shouldStart = !isPlaying
        let cleanup = stop()
        guard shouldStart else { return }
        notice = nil
        isPlaying = true
        let revision = revision
        operation = Task { [weak self] in
            await cleanup?.value
            guard let self, self.revision == revision else { return }
            guard allowed() else { stop(); return }
            playSpeaker(device: device, revision: revision)
        }
    }

    private func playSpeaker(device: String, revision: Int) {
        let route = makeRoute()
        self.route = route
        do {
            try route.playSpeaker(device: device) { [weak self] success in
                guard let self, self.revision == revision else { return }
                if success {
                    stop()
                } else {
                    fail("Couldn’t play the speaker test.")
                }
            }
        } catch {
            fail("Couldn’t play the speaker test.")
        }
    }

    func suspend() {
        if microphoneStarted || isPlaying {
            stop()
        }
    }

    @discardableResult
    func stop() -> Task<Void, Never>? {
        revision += 1
        operation?.cancel()
        operation = nil
        if let route {
            route.stopSpeaker()
            if microphoneStarted {
                cleanup = route.stopMicrophone()
            }
        }
        route = nil
        microphoneStarted = false
        if microphone != .off {
            microphone = .off
        }
        if isPlaying {
            isPlaying = false
        }
        return cleanup
    }

    private func fail(_ message: String) {
        stop()
        notice = message
    }

    isolated deinit {
        operation?.cancel()
        route?.stopSpeaker()
        if microphoneStarted {
            _ = route?.stopMicrophone()
        }
    }
}
