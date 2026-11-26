import SwiftUI

/// Local presentation values. Hardware identifiers never enter call signaling.
public struct CallAudioDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct CallAudioDevices: Equatable, Sendable {
    public var microphones: [CallAudioDevice]
    public var speakers: [CallAudioDevice]
    public var microphone: String
    public var speaker: String
    public var isUpdating: Bool
    public var notice: String?

    public init(
        microphones: [CallAudioDevice], speakers: [CallAudioDevice],
        microphone: String = "", speaker: String = "", isUpdating: Bool = false, notice: String? = nil
    ) {
        self.microphones = microphones
        self.speakers = speakers
        self.microphone = microphone
        self.speaker = speaker
        self.isUpdating = isUpdating
        self.notice = notice
    }
}

@MainActor
public struct CallSpeakerTestAction {
    public let isPlaying: Bool
    public let toggle: () -> Void

    public init(isPlaying: Bool, toggle: @escaping () -> Void) {
        self.isPlaying = isPlaying
        self.toggle = toggle
    }
}

/// Microphone and speaker choices, as sections of the call's device menu.
/// Each lists System Default first and checks the current choice. An inline
/// picker heads its own section; wrapping it in a `Section` as well draws a
/// rule under the heading that native menus do not have.
struct CallAudioDeviceSections: View {
    let devices: CallAudioDevices
    let selectMicrophone: (String) -> Void
    let selectSpeaker: (String) -> Void
    var openMicrophoneModes: (() -> Void)?
    var checkMicrophone: (() -> Void)?
    var speakerTest: CallSpeakerTestAction?

    var body: some View {
        CallAudioDevicePicker(
            title: "Microphone", devices: devices.microphones, selection: devices.microphone,
            select: selectMicrophone
        )
        .pickerStyle(.inline)
        .disabled(devices.isUpdating)
        if let checkMicrophone {
            Button("Microphone Level…", systemImage: "mic", action: checkMicrophone)
        }
        if let openMicrophoneModes {
            Button("Mic Mode…", systemImage: "waveform", action: openMicrophoneModes)
        }
        CallAudioDevicePicker(
            title: "Speaker", devices: devices.speakers, selection: devices.speaker, select: selectSpeaker
        )
        .pickerStyle(.inline)
        .disabled(devices.isUpdating)
        if let speakerTest {
            Button(
                speakerTest.isPlaying ? "Stop Speaker Test" : "Test Speakers",
                systemImage: speakerTest.isPlaying ? "stop.fill" : "speaker.wave.2",
                action: speakerTest.toggle
            )
            .disabled(devices.isUpdating)
        }
    }
}

struct CallAudioDevicePicker: View {
    let title: String
    let devices: [CallAudioDevice]
    let selection: String
    let select: (String) -> Void

    var body: some View {
        Picker(title, selection: Binding(get: { selection }, set: { select($0) })) {
            Text("System Default").tag("")
            ForEach(devices) { Text($0.name).tag($0.id) }
        }
    }
}
