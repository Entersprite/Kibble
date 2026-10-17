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

struct CallAudioDevicesView: View {
    let devices: CallAudioDevices
    let selectMicrophone: (String) -> Void
    let selectSpeaker: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Microphone").gridColumnAlignment(.trailing)
                    Picker(
                        "Microphone",
                        selection: Binding(get: { devices.microphone }, set: { selectMicrophone($0) })
                    ) {
                        Text("System Default").tag("")
                        ForEach(devices.microphones) { Text($0.name).tag($0.id) }
                    }
                }
                GridRow {
                    Text("Speaker")
                    Picker(
                        "Speaker",
                        selection: Binding(get: { devices.speaker }, set: { selectSpeaker($0) })
                    ) {
                        Text("System Default").tag("")
                        ForEach(devices.speakers) { Text($0.name).tag($0.id) }
                    }
                }
            }
            .labelsHidden()
            if let notice = devices.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(
                    horizontal: false,
                    vertical: true
                )
            }
        }
        .disabled(devices.isUpdating)
        .controlSize(.regular)
    }
}
