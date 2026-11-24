import SwiftUI

public struct CallCameraDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id; self.name = name
    }
}

public struct CallCameraState: Equatable, Sendable {
    public var devices: [CallCameraDevice]
    public var selected: String
    public var isOn: Bool
    public var isUpdating: Bool
    public var notice: String?
    public var allowsStart: Bool

    public init(
        devices: [CallCameraDevice] = [],
        selected: String = "",
        isOn: Bool = false,
        isUpdating: Bool = false,
        notice: String? = nil,
        allowsStart: Bool = true
    ) {
        self.devices = devices; self.selected = selected; self.isOn = isOn
        self.isUpdating = isUpdating; self.notice = notice
        self.allowsStart = allowsStart
    }

    public var canToggle: Bool {
        !isUpdating && (isOn || allowsStart)
    }
}

/// Turns the camera on and off. The glyph shows the camera's state; your
/// preview appearing is the stronger signal that it is on.
struct CallCameraButton: View {
    let camera: CallCameraState
    let toggle: () -> Void

    var body: some View {
        CallRoundButton(
            title: camera.isOn ? "Turn Camera Off" : "Turn Camera On",
            symbol: camera.isOn ? "video.fill" : "video.slash.fill",
            action: toggle
        )
        .disabled(!camera.canToggle)
    }
}

/// The camera choice, as a section of the call's device menu.
struct CallCameraSection: View {
    let camera: CallCameraState
    let select: (String) -> Void
    var openVideoEffects: (() -> Void)?

    var body: some View {
        CallCameraPicker(devices: camera.devices, selection: camera.selected, select: select)
            .pickerStyle(.inline)
            .disabled(camera.isUpdating)
        if let openVideoEffects {
            Button("Video Effects…", systemImage: "video.badge.waveform", action: openVideoEffects)
        }
    }
}

struct CallCameraPicker: View {
    let devices: [CallCameraDevice]
    let selection: String
    let select: (String) -> Void

    var body: some View {
        Picker("Camera", selection: Binding(get: { selection }, set: { select($0) })) {
            Text("Default Camera").tag("")
            ForEach(devices) { Text($0.name).tag($0.id) }
        }
    }
}
