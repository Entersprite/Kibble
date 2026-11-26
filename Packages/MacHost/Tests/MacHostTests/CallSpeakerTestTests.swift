import Foundation
import Testing
@testable import MacHost

@MainActor
extension CallAudioDeviceTests {
    @Test func speakerTestUsesTheActiveOutputAndRetiresTheOldPlayback() async throws {
        let playback = SpeakerPlaybackFixture()
        let controller = CallAudioDeviceController(
            preferences: nil, speakerPlayback: playback, defaultOutput: { "default-output" }
        )
        let hardware = FakeCallAudioHardware()
        let route = NativeCallAudioRouting(hardware: hardware)
        let scope = controller.install(route)
        defer { controller.clear(); route.close() }
        try await settle(controller)
        controller.toggleSpeakerTest(in: scope) { true }
        try await waitForPlayback(playback, count: 1)
        #expect(playback.devices == ["default-output"])
        #expect(hardware.state.withLock { $0.changes.isEmpty })
        controller.select("speaker:usb", microphone: false)
        #expect(!controller.isTestingSpeaker && playback.stopCount == 1)
        try await settle(controller)
        controller.toggleSpeakerTest(in: scope) { true }
        try await waitForPlayback(playback, count: 2)
        #expect(playback.devices == ["default-output", "uid:speaker:usb"])
        playback.completions.first?(false)
        #expect(controller.isTestingSpeaker && controller.devices?.notice == nil)
        playback.completions.last?(true)
        #expect(!controller.isTestingSpeaker && controller.devices?.notice == nil)
        #expect(hardware.state.withLock { $0.changes } == ["output:speaker:usb"])
    }

    @Test func refusingPlaybackKeepsTheAudioSelectionAndMakesRetryAvailable() async throws {
        let playback = SpeakerPlaybackFixture()
        let controller = CallAudioDeviceController(
            preferences: nil, speakerPlayback: playback, defaultOutput: { "default-output" }
        )
        let route = NativeCallAudioRouting(hardware: FakeCallAudioHardware())
        let scope = controller.install(route)
        defer { controller.clear(); route.close() }
        try await settle(controller)
        controller.toggleSpeakerTest(in: scope) { true }
        try await waitForPlayback(playback, count: 1)
        playback.completions.first?(false)
        #expect(controller.devices?.notice == "Couldn’t play the speaker test.")
        #expect(controller.devices?.speaker == "" && !controller.isTestingSpeaker)
        controller.toggleSpeakerTest(in: scope) { true }
        try await waitForPlayback(playback, count: 2)
        #expect(controller.devices?.notice == nil)
        controller.clear(ifCurrent: scope)
        playback.completions.last?(false)
        #expect(controller.devices == nil && !controller.isTestingSpeaker)
    }

    private func waitForPlayback(_ playback: SpeakerPlaybackFixture, count: Int) async throws {
        for _ in 0 ..< 200 where playback.devices.count < count {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(playback.devices.count == count)
    }
}

@MainActor
final class SpeakerPlaybackFixture: CallSpeakerPlayback {
    private(set) var devices: [String] = []
    private(set) var completions: [(Bool) -> Void] = []
    private(set) var stopCount = 0

    func play(device uid: String, completion: @escaping (Bool) -> Void) throws {
        devices.append(uid)
        completions.append(completion)
    }

    func stop() {
        stopCount += 1
    }
}
