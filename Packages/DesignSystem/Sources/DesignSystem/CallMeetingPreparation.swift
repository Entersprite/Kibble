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

struct CallMeetingPreparationControls: View {
    let preparation: CallMeetingPreparation

    var body: some View {
        VStack(spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 15, verticalSpacing: 8) {
                microphone
                camera
                speaker
            }
            .font(.callout)
            if let notice = preparation.audioChecks?.notice ?? preparation.cameraPreview?.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("Cancel", action: preparation.cancel)
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button(preparation.isJoining ? "Joining…" : "Join Now", action: preparation.join)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preparation.isJoining)
            }
            .controlSize(.large)
        }
    }

    @ViewBuilder private var microphone: some View {
        if let checks = preparation.audioChecks, let toggleMicrophone = checks.toggleMicrophone {
            GridRow {
                audioLabel("Microphone", symbol: "mic", microphone: true)
                HStack(spacing: 8) {
                    Button(microphoneTitle(checks.microphone), action: toggleMicrophone)
                        .disabled(preparation.isJoining)
                    if case let .active(level) = checks.microphone {
                        ProgressView(value: level) { Text("Microphone level") }
                            .labelsHidden()
                            .frame(width: 60)
                    }
                }
            }
        } else {
            GridRow {
                audioLabel("Microphone", symbol: "mic", microphone: true)
                Text(preparation.microphone.title).foregroundStyle(.secondary)
            }
        }
    }

    private var speaker: some View {
        GridRow {
            audioLabel("Speakers", symbol: "speaker.wave.2", microphone: false)
            if let checks = preparation.audioChecks, let toggleSpeaker = checks.toggleSpeaker {
                Button(checks.isPlaying ? "Stop Test" : "Test Speakers", action: toggleSpeaker)
                    .disabled(preparation.isJoining)
            } else {
                Text((preparation.hasSpeaker ? CallMeetingPreparation.DeviceStatus.ready : .unavailable)
                    .title)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func audioLabel(_ title: String, symbol: String, microphone: Bool) -> some View {
        let choices = preparation.audioSelection
        let devices = microphone ? choices?.devices.microphones : choices?.devices.speakers
        if let choices, let devices, !devices.isEmpty {
            let selection = microphone ? choices.devices.microphone : choices.devices.speaker
            Menu {
                CallAudioDevicePicker(
                    title: title, devices: devices, selection: selection,
                    select: microphone ? choices.selectMicrophone : choices.selectSpeaker
                )
                .pickerStyle(.inline)
            } label: {
                Label(title, systemImage: symbol)
            }
            .fixedSize()
            .disabled(preparation.isJoining)
            .accessibilityValue(devices.first { $0.id == selection }?.name ?? "System Default")
        } else {
            Label(title, systemImage: symbol)
        }
    }

    private func microphoneTitle(_ check: CallPreparationAudioChecks.Microphone) -> String {
        switch check {
        case .off: "Test Microphone"
        case .starting: "Cancel Test"
        case .active: "Stop Test"
        }
    }

    private var camera: some View {
        GridRow {
            cameraLabel
            if let preview = preparation.cameraPreview {
                Button(previewTitle(preview), action: preview.toggle)
                    .disabled(preparation.isJoining)
            } else {
                Text(preparation.camera.title).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var cameraLabel: some View {
        if let selection = preparation.cameraSelection, !selection.devices.isEmpty {
            Menu {
                CallCameraPicker(
                    devices: selection.devices,
                    selection: selection.selection,
                    select: selection.select
                )
                .pickerStyle(.inline)
            } label: {
                Label("Camera", systemImage: "video")
            }
            .fixedSize()
            .disabled(preparation.isJoining)
            .accessibilityValue(selection.devices.first { $0.id == selection.selection }?
                .name ?? "Default Camera")
        } else {
            Label("Camera", systemImage: "video")
        }
    }

    private func previewTitle(_ preview: CallPreparationCameraPreview) -> String {
        if preview.isStarting {
            return "Cancel Preview"
        }
        return preview.content == nil ? "Preview Camera" : "Stop Preview"
    }
}
