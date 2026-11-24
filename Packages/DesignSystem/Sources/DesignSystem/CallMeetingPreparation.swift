import SwiftUI

@MainActor
public struct CallMeetingPreparation {
    public enum DeviceStatus: Sendable {
        case ready, needsPermission, accessOff, unavailable

        var title: String {
            switch self {
            case .ready: "Available"
            case .needsPermission: "Permission needed"
            case .accessOff: "Access off"
            case .unavailable: "Unavailable"
            }
        }
    }

    public var microphone: DeviceStatus
    public var camera: DeviceStatus
    public var join: () -> Void
    public let cancel: () -> Void
    public var canCheckDevices: () -> Bool = { true }
    public var hasSpeaker = false
    public var cameraPreview: CallPreparationCameraPreview?
    public var cameraSelection: CallPreparationCameraSelection?
    public var audioChecks: CallPreparationAudioChecks?
    public var audioSelection: CallPreparationAudioSelection?
    public var isJoining = false

    public init(
        microphone: DeviceStatus,
        camera: DeviceStatus,
        join: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        self.microphone = microphone
        self.camera = camera
        self.join = join
        self.cancel = cancel
    }
}

@MainActor
public struct CallPreparationCameraSelection {
    public let devices: [CallCameraDevice]
    public let selection: String
    public let select: (String) -> Void

    public init(devices: [CallCameraDevice], selection: String, select: @escaping (String) -> Void) {
        self.devices = devices
        self.selection = selection
        self.select = select
    }
}

@MainActor
public struct CallPreparationAudioSelection {
    public let devices: CallAudioDevices
    public let selectMicrophone: (String) -> Void
    public let selectSpeaker: (String) -> Void

    public init(
        devices: CallAudioDevices,
        selectMicrophone: @escaping (String) -> Void,
        selectSpeaker: @escaping (String) -> Void
    ) {
        self.devices = devices
        self.selectMicrophone = selectMicrophone
        self.selectSpeaker = selectSpeaker
    }
}

@MainActor
public struct CallPreparationAudioChecks {
    public enum Microphone: Equatable, Sendable {
        case off, starting, active(Double)
    }

    public let microphone: Microphone
    public let toggleMicrophone: (() -> Void)?
    public let isPlaying: Bool
    public let toggleSpeaker: (() -> Void)?
    public let notice: String?

    public init(
        microphone: Microphone, toggleMicrophone: (() -> Void)?,
        isPlaying: Bool, toggleSpeaker: (() -> Void)?, notice: String?
    ) {
        self.microphone = microphone
        self.toggleMicrophone = toggleMicrophone
        self.isPlaying = isPlaying
        self.toggleSpeaker = toggleSpeaker
        self.notice = notice
    }
}

@MainActor
public struct CallPreparationCameraPreview {
    public let content: AnyView?
    public let isStarting: Bool
    public let notice: String?
    public let toggle: () -> Void

    public init(content: AnyView?, isStarting: Bool, notice: String?, toggle: @escaping () -> Void) {
        self.content = content
        self.isStarting = isStarting
        self.notice = notice
        self.toggle = toggle
    }
}
