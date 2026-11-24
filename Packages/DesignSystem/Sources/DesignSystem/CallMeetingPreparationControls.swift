import SwiftUI

/// What a meeting's window shows before you join: the microphone, camera and
/// speakers you will join with, each with the device in use and a way to try
/// it, then Cancel and Join.
///
/// One panel of three rows in the compact call window's column. A row names
/// the device under its title; where the host lists more than one, the name
/// is a menu. A device that cannot be used says why in the same place. The
/// trailing control tries the device, and is there only when the host can.
struct CallMeetingPreparationControls: View {
    let preparation: CallMeetingPreparation

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                microphone
                rule
                camera
                rule
                speaker
            }
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Button("Cancel", action: preparation.cancel)
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button(preparation.isJoining ? "Joining…" : "Join", action: preparation.join)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preparation.isJoining)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: 320)
    }

    private var rule: some View {
        Divider().overlay(.white.opacity(0.06)).padding(.leading, 42)
    }

    /// The audio checks' notice first: it is the one a test just produced.
    private var notice: String? {
        preparation.audioChecks?.notice ?? preparation.cameraPreview?.notice
    }

    // MARK: Rows

    private var microphone: some View {
        let checks = preparation.audioChecks
        return CallPreparationRow(title: "Microphone", symbol: "mic.fill") {
            audioDevice(
                "Microphone", devices: preparation.audioSelection?.devices.microphones,
                selection: preparation.audioSelection?.devices.microphone,
                select: preparation.audioSelection?.selectMicrophone,
                status: preparation.microphone
            )
            if case let .active(level)? = checks?.microphone {
                ProgressView(value: min(max(level, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(.green)
                    .accessibilityLabel("Microphone level")
            }
        } trailing: {
            if let checks, let toggle = checks.toggleMicrophone {
                tryButton(Self.microphoneTest(checks.microphone), action: toggle)
            }
        }
    }

    private var camera: some View {
        CallPreparationRow(title: "Camera", symbol: "video.fill") {
            if let choices = preparation.cameraSelection, !choices.devices.isEmpty {
                CallPreparationDeviceMenu(
                    title: "Camera",
                    name: choices.devices.first { $0.id == choices.selection }?.name ?? "Default Camera"
                ) {
                    CallCameraPicker(
                        devices: choices.devices, selection: choices.selection, select: choices.select
                    )
                }
                .disabled(preparation.isJoining)
            } else {
                CallPreparationStatus(status: preparation.camera)
            }
        } trailing: {
            if let preview = preparation.cameraPreview {
                tryButton(Self.cameraPreview(preview), action: preview.toggle)
            }
        }
    }

    private var speaker: some View {
        let checks = preparation.audioChecks
        return CallPreparationRow(title: "Speakers", symbol: "speaker.wave.2.fill") {
            audioDevice(
                "Speakers", devices: preparation.audioSelection?.devices.speakers,
                selection: preparation.audioSelection?.devices.speaker,
                select: preparation.audioSelection?.selectSpeaker,
                status: preparation.hasSpeaker ? .ready : .unavailable
            )
        } trailing: {
            if let checks, let toggle = checks.toggleSpeaker {
                tryButton(Self.speakerTest(isPlaying: checks.isPlaying), action: toggle)
            }
        }
    }

    /// The device in use as a menu of the choices, or what stands in the way.
    @ViewBuilder private func audioDevice(
        _ title: String, devices: [CallAudioDevice]?, selection: String?,
        select: ((String) -> Void)?, status: CallMeetingPreparation.DeviceStatus
    ) -> some View {
        if let devices, !devices.isEmpty, let selection, let select {
            CallPreparationDeviceMenu(
                title: title, name: devices.first { $0.id == selection }?.name ?? "System Default"
            ) {
                CallAudioDevicePicker(title: title, devices: devices, selection: selection, select: select)
            }
            .disabled(preparation.isJoining)
            // A device can be listed and still not be usable yet.
            if status != .ready {
                CallPreparationStatus(status: status)
            }
        } else {
            CallPreparationStatus(status: status)
        }
    }

    private func tryButton(_ test: CallPreparationTest, action: @escaping () -> Void) -> some View {
        Button(test.title, action: action)
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(preparation.isJoining)
            .accessibilityLabel(test.label)
            .help(test.label)
    }

    // MARK: Words

    static func microphoneTest(_ check: CallPreparationAudioChecks.Microphone) -> CallPreparationTest {
        switch check {
        case .off: CallPreparationTest(title: "Test", label: "Test Microphone")
        case .starting: CallPreparationTest(title: "Cancel", label: "Cancel Microphone Test")
        case .active: CallPreparationTest(title: "Stop", label: "Stop Microphone Test")
        }
    }

    static func speakerTest(isPlaying: Bool) -> CallPreparationTest {
        isPlaying
            ? CallPreparationTest(title: "Stop", label: "Stop Speaker Test")
            : CallPreparationTest(title: "Test", label: "Test Speakers")
    }

    static func cameraPreview(_ preview: CallPreparationCameraPreview) -> CallPreparationTest {
        if preview.isStarting {
            return CallPreparationTest(title: "Cancel", label: "Cancel Camera Preview")
        }
        return preview.content == nil
            ? CallPreparationTest(title: "Preview", label: "Preview Camera")
            : CallPreparationTest(title: "Stop", label: "Stop Camera Preview")
    }
}

/// A trying control's short title, which the row's own title completes, and
/// the whole phrase for VoiceOver and the tooltip.
struct CallPreparationTest: Equatable {
    let title: String
    let label: String
}

/// One device: its glyph, its title over the device in use, and a control.
private struct CallPreparationRow<Detail: View, Trailing: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var detail: Detail
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

/// The device in use, as a quiet menu of the others: its name and a small
/// chevron, the way a pop-up reads without its bezel.
private struct CallPreparationDeviceMenu<Choices: View>: View {
    let title: String
    let name: String
    @ViewBuilder var choices: Choices

    var body: some View {
        Menu {
            choices.pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 3) {
                Text(name).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(title)
        .accessibilityValue(name)
        .help("Choose the \(title.lowercased()) to join with")
    }
}

/// Why a device cannot be chosen or tried, with a caution mark unless it is
/// simply ready.
private struct CallPreparationStatus: View {
    let status: CallMeetingPreparation.DeviceStatus

    var body: some View {
        HStack(spacing: 4) {
            if status != .ready {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
            }
            Text(status.title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
