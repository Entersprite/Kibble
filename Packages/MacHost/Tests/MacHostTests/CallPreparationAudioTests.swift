import AVFoundation
import Foundation
import Testing
@testable import MacHost

@MainActor
struct CallPreparationAudioTests {
    @Test func latePermissionCannotStartTheMicrophoneOfAReplacedPreparation() async {
        let route = AudioTestRoute()
        route.holdsPermission = true
        let audio = CallPreparationAudio { route }
        let id = UUID()
        audio.bind(id)
        audio.configure(microphone: "mic", speaker: "speaker")
        audio.toggleMicrophone(in: id) { true }
        #expect(await eventually { route.permission != nil })
        audio.bind(UUID())
        route.permission?.resume(returning: true)
        route.permission = nil
        await Task.yield()
        #expect(audio.microphone == .off && route.microphoneStarts == 0)
    }

    @Test func speakerPlaybackWaitsForMicrophoneReleaseAndHonorsCompletion() async {
        let microphone = AudioTestRoute()
        microphone.holdsStop = true
        let speaker = AudioTestRoute()
        var routes = [microphone, speaker]
        let audio = CallPreparationAudio { routes.removeFirst() }
        let id = UUID()
        audio.bind(id)
        audio.configure(microphone: "mic", speaker: "speaker")
        audio.toggleMicrophone(in: id) { true }
        #expect(await eventually { audio.microphone == .active(0.42) })
        audio.toggleSpeaker(in: id) { true }
        #expect(audio.microphone == .off && audio.isPlaying && speaker.playback == nil)
        microphone.releaseMicrophone()
        #expect(await eventually { speaker.playback != nil })
        speaker.playback?(true)
        #expect(!audio.isPlaying && audio.notice == nil)
        #expect(microphone.input == "mic" && speaker.output == "speaker")
    }

    @Test func joinAwaitsMicrophoneRelease() async {
        let route = AudioTestRoute()
        route.holdsStop = true
        let audio = CallPreparationAudio { route }
        let camera = CallPreparationCamera()
        let id = UUID()
        camera.bind(id)
        audio.bind(id)
        audio.configure(microphone: "mic", speaker: "speaker")
        audio.toggleMicrophone(in: id) { true }
        #expect(await eventually { audio.microphone == .active(0.42) })
        var joined = false
        camera.join(id, after: audio.stop()) { joined = true }
        #expect(camera.isJoining && !joined && audio.microphone == .off)
        route.releaseMicrophone()
        #expect(await eventually { joined && !camera.isJoining })
    }

    @Test func changingDevicesStopsAProbeAndSendsTheReplacementUIDToTheNativeAdapter() async {
        let route = AudioTestRoute()
        let audio = CallPreparationAudio { route }
        let id = UUID()
        audio.bind(id)
        audio.configure(microphone: nil, speaker: "first-output")
        audio.toggleSpeaker(in: id) { true }
        #expect(await eventually { route.output == "first-output" })
        let stale = route.playback
        audio.configure(microphone: nil, speaker: "next-output")
        #expect(!audio.isPlaying && route.playback == nil)
        audio.toggleSpeaker(in: id) { true }
        #expect(await eventually { route.output == "next-output" })
        stale?(false)
        #expect(audio.isPlaying && audio.notice == nil)
        audio.stop()
    }

    @Test func theMeterUsesTheLoudestChannelAndBoundsItsRange() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let channels = try #require(buffer.floatChannelData)
        channels[0].initialize(repeating: 0, count: 4)
        channels[1].initialize(repeating: 0.5, count: 4)
        #expect(MicrophoneLevel
            .power(frameCount: Int(buffer.frameLength), channels: buffer.audioBufferList) == 0.25)
        #expect(MicrophoneLevel.normalized(power: 0) == 0)
        #expect(MicrophoneLevel.normalized(power: .nan) == 0)
        #expect(MicrophoneLevel.normalized(power: 0.01) > 0.5)
        #expect(MicrophoneLevel.normalized(power: 2) == 1)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 200 {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

@MainActor
private final class AudioTestRoute: CallPreparationAudioRoute {
    var holdsPermission = false
    var holdsStop = false
    var permission: CheckedContinuation<Bool, Never>?
    var playback: ((Bool) -> Void)?
    var microphoneStarts = 0
    var input: String?
    var output: String?
    private var stopping: AsyncStream<Void>.Continuation?
    var microphoneLevel: Double? {
        0.42
    }

    func authorizeMicrophone() async -> Bool {
        guard holdsPermission else { return true }
        return await withCheckedContinuation { permission = $0 }
    }

    func startMicrophone(device uid: String) async -> Bool {
        microphoneStarts += 1
        input = uid
        return true
    }

    func stopMicrophone() -> Task<Void, Never> {
        guard holdsStop else { return Task {} }
        let (release, signal) = AsyncStream<Void>.makeStream()
        stopping = signal
        return Task { for await _ in release {} }
    }

    func releaseMicrophone() {
        stopping?.finish()
        stopping = nil
    }

    func playSpeaker(device uid: String, completion: @escaping (Bool) -> Void) throws {
        output = uid
        playback = completion
    }

    func stopSpeaker() {
        playback = nil
    }
}
