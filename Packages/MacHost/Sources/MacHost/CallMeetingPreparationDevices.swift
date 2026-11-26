import AppCore
import AppKit
import AVFoundation
import DesignSystem
import Foundation
import SwiftUI

@MainActor
enum CallMeetingPreparationDevices {
    static func scene(
        for id: UUID, calls: AudioCallController, canJoinWithCamera: Bool
    ) -> CallMeetingPreparation? {
        guard calls.meetingPreparationID == id else { return nil }
        var preparation = CallMeetingPreparation(
            microphone: .unavailable,
            camera: .unavailable,
            join: { [weak calls] in calls?.joinPreparedMeeting(id) },
            cancel: { [weak calls] in calls?.cancelMeetingPreparation(id) }
        )
        preparation.canCheckDevices = { [weak calls] in calls?.meetingPreparationID == id }
        if let media = calls.meetingJoinMedia(for: id) {
            preparation.joinMedia = Binding(
                get: { [weak calls] in calls?.meetingJoinMedia(for: id) ?? media },
                set: { [weak calls] in calls?.setMeetingJoinMedia($0, for: id) }
            )
            preparation.canJoinWithCamera = canJoinWithCamera
        }
        preparation.openMicrophoneSettings = { openPrivacySettings(for: .audio) }
        preparation.openCameraSettings = { openPrivacySettings(for: .video) }
        return preparation
    }

    static func privacySettingsURL(for media: AVMediaType) -> URL? {
        let pane: String
        switch media {
        case .audio: pane = "Privacy_Microphone"
        case .video: pane = "Privacy_Camera"
        default: return nil
        }
        return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)")
    }

    private static func openPrivacySettings(for media: AVMediaType) {
        guard let url = privacySettingsURL(for: media) else { return }
        NSWorkspace.shared.open(url)
    }

    static func microphoneStatus(hasDevice: Bool) -> CallMeetingPreparation.DeviceStatus {
        status(hasDevice: hasDevice, authorization: AVCaptureDevice.authorizationStatus(for: .audio))
    }

    static func cameraStatus(hasDevice: Bool) -> CallMeetingPreparation.DeviceStatus {
        status(hasDevice: hasDevice, authorization: AVCaptureDevice.authorizationStatus(for: .video))
    }

    static func status(
        hasDevice: Bool, authorization: AVAuthorizationStatus
    ) -> CallMeetingPreparation.DeviceStatus {
        guard hasDevice else { return .unavailable }
        switch authorization {
        case .authorized: return .ready
        case .notDetermined: return .needsPermission
        case .denied, .restricted: return .accessOff
        @unknown default: return .unavailable
        }
    }
}
