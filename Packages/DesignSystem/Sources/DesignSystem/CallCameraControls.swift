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

struct CallCameraControls: View {
    let camera: CallCameraState
    let toggle: () -> Void
    let select: (String) -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button(
                    camera.isOn ? "Turn Camera Off" : "Turn Camera On",
                    systemImage: camera.isOn ? "video.fill" : "video.slash.fill",
                    action: toggle
                )
                Picker("Camera", selection: Binding(get: { camera.selected }, set: { select($0) })) {
                    Text("Default Camera").tag("")
                    ForEach(camera.devices) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }
            .disabled(camera.isUpdating)
            if let notice = camera.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }
}
