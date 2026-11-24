import AppCore
import AVFoundation
import DesignSystem
import Foundation

/// Local controls for this call's active capture and playback routes.
@MainActor
enum CallSystemMediaControls {
    static func add(
        to actions: inout AudioCallActions,
        callID: UUID,
        calls: AudioCallController,
        audio: CallAudioDeviceController,
        video: CallVideoController,
        present: @escaping (AVCaptureDevice.SystemUserInterface) -> Void = AVCaptureDevice
            .showSystemUserInterface
    ) {
        guard isConnected(callID, calls) else { return }
        actions.microphoneLevel = microphoneLevel(for: callID, calls: calls, audio: audio)
        if let scope = audio.speakerTestScope {
            actions.speakerTest = .init(isPlaying: audio.isTestingSpeaker) { [weak calls, weak audio] in
                audio?.toggleSpeakerTest(in: scope) { [weak calls] in
                    guard let calls else { return false }
                    return isConnected(callID, calls)
                }
            }
        }
        if let scope = liveCameraScope(video) {
            actions.openVideoEffects = { [weak calls, weak video] in
                guard let calls, let video, isConnected(callID, calls), liveCameraScope(video) == scope else {
                    return
                }
                present(.videoEffects)
            }
        }
        if let scope = liveMicrophoneScope(audio, calls) {
            actions.openMicrophoneModes = { [weak calls, weak audio] in
                guard let calls, let audio, isConnected(callID, calls),
                      liveMicrophoneScope(audio, calls) == scope else {
                    return
                }
                present(.microphoneModes)
            }
        }
    }

    private static func isConnected(_ callID: UUID, _ calls: AudioCallController) -> Bool {
        calls.call?.id == callID && calls.call?.phase == .connected && !calls.isEnding
    }

    private static func liveCameraScope(_ video: CallVideoController) -> UUID? {
        guard let camera = video.camera, camera.isOn, !camera.isUpdating,
              camera.allowsStart else { return nil }
        return video.receivePreferenceScope
    }

    private static func liveMicrophoneScope(
        _ audio: CallAudioDeviceController,
        _ calls: AudioCallController
    ) -> UUID? {
        guard calls.call?.isMuted == false, !calls.isUpdatingMute,
              calls.interaction?.activities?.microphoneRestricted != true else {
            return nil
        }
        return audio.microphoneModeScope
    }

    private static func microphoneLevel(
        for callID: UUID, calls: AudioCallController, audio: CallAudioDeviceController
    ) -> CallMicrophoneLevelAction? {
        guard let scope = audio.microphoneLevelScope else { return nil }
        let read: @MainActor () async -> Double? = { [weak calls, weak audio] in
            guard let calls, let audio, canReadMicrophoneLevel(callID, calls, audio) else { return nil }
            let level = await audio.microphoneLevel(in: scope)
            return canReadMicrophoneLevel(callID, calls, audio) ? level : nil
        }
        return CallMicrophoneLevelAction(
            id: scope,
            isMuted: liveMicrophoneScope(audio, calls) == nil,
            read: read
        )
    }

    private static func canReadMicrophoneLevel(
        _ callID: UUID, _ calls: AudioCallController, _ audio: CallAudioDeviceController
    ) -> Bool {
        isConnected(callID, calls) && liveMicrophoneScope(audio, calls) != nil
    }
}
