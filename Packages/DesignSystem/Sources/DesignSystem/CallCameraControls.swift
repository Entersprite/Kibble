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

    public init(
        devices: [CallCameraDevice] = [],
        selected: String = "",
        isOn: Bool = false,
        isUpdating: Bool = false,
        notice: String? = nil
    ) {
        self.devices = devices; self.selected = selected; self.isOn = isOn
        self.isUpdating = isUpdating; self.notice = notice
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
        .disabled(camera.isUpdating)
    }
}

/// The camera choice, as a section of the call's device menu.
struct CallCameraSection: View {
    let camera: CallCameraState
    let select: (String) -> Void

    var body: some View {
        Picker("Camera", selection: Binding(get: { camera.selected }, set: { select($0) })) {
            Text("Default Camera").tag("")
            ForEach(camera.devices) { Text($0.name).tag($0.id) }
        }
        .pickerStyle(.inline)
        .disabled(camera.isUpdating)
    }
}
