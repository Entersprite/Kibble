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

/// Microphone and speaker choices, as sections of the call's device menu.
/// Each lists System Default first and checks the current choice. An inline
/// picker heads its own section; wrapping it in a `Section` as well draws a
/// rule under the heading that native menus do not have.
struct CallAudioDeviceSections: View {
    let devices: CallAudioDevices
    let selectMicrophone: (String) -> Void
    let selectSpeaker: (String) -> Void

    var body: some View {
        Picker("Microphone", selection: Binding(get: { devices.microphone }, set: { selectMicrophone($0) })) {
            Text("System Default").tag("")
            ForEach(devices.microphones) { Text($0.name).tag($0.id) }
        }
        .pickerStyle(.inline)
        .disabled(devices.isUpdating)
        Picker("Speaker", selection: Binding(get: { devices.speaker }, set: { selectSpeaker($0) })) {
            Text("System Default").tag("")
            ForEach(devices.speakers) { Text($0.name).tag($0.id) }
        }
        .pickerStyle(.inline)
        .disabled(devices.isUpdating)
    }
}
