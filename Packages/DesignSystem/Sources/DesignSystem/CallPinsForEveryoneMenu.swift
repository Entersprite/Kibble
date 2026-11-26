import ChatKit
import SwiftUI

struct CallPinsForEveryoneMenu: View {
    let devices: [CallParticipantDevice]
    let limit: Int?
    let busy: Bool
    let change: (CallParticipantDevice, String) -> Void

    var body: some View {
        let targets = devices.filter { $0.isPinnedForEveryone != nil }
        let count = targets.filter { $0.isPinnedForEveryone == true }.count
        let atLimit = limit.map { count >= $0 } ?? false
        if !targets.isEmpty {
            let labels = CallRoster.disambiguatedNames(in: devices)
            Menu("Pins for Everyone", systemImage: "pin") {
                ForEach(targets, id: \.id) { device in
                    let name = label(for: device, names: labels)
                    let pinned = device.isPinnedForEveryone == true
                    Button(
                        pinned ? "Unpin \(name)…" : "Pin \(name)",
                        systemImage: pinned ? "pin.slash" : "pin"
                    ) {
                        change(device, name)
                    }
                    .disabled(!pinned && atLimit)
                }
            }
            .disabled(busy)
        }
    }

    private func label(for device: CallParticipantDevice, names: [UUID: String]) -> String {
        let parent = device.parentID.flatMap { id in devices.first { $0.id == id } }
        if device.isPresentation {
            if device.isLocal {
                return "your presentation"
            }
            return parent.map { (names[$0.id] ?? CallRoster.name(
                of: $0
            )) + "’s presentation" } ?? "shared screen"
        }
        return device.isLocal ? "your tile" : names[device.id] ?? CallRoster.name(of: device)
    }
}
