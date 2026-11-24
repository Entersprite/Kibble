import AppCore
import AVFoundation
import DesignSystem
import Foundation

@MainActor
enum CallMeetingPreparationDevices {
    static func scene(for id: UUID, calls: AudioCallController) -> CallMeetingPreparation? {
        guard calls.meetingPreparationID == id else { return nil }
        var preparation = CallMeetingPreparation(
            microphone: .unavailable,
            camera: .unavailable,
            join: { [weak calls] in calls?.joinPreparedMeeting(id) },
            cancel: { [weak calls] in calls?.cancelMeetingPreparation(id) }
        )
        preparation.canCheckDevices = { [weak calls] in calls?.meetingPreparationID == id }
        return preparation
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
