import SwiftUI

struct CallPersonalPinsMenu: View {
    @Binding var selection: CallStageSelection
    let videos: [CallRemoteVideo]

    var body: some View {
        let targets = videos.filter { $0.participantID != nil }
        if !targets.isEmpty {
            Menu("Pins for Me", systemImage: "pin") {
                ForEach(targets) { video in
                    CallPersonalPinButton(video: video, selection: selection, includeName: true) {
                        selection.togglePin(video)
                    }
                }
                if selection.pinCount >= CallStageSelection.pinLimit {
                    Text("You can pin up to \(CallStageSelection.pinLimit) tiles.")
                }
            }
        }
    }
}

struct CallPersonalPinButton: View {
    let video: CallRemoteVideo
    let selection: CallStageSelection
    var includeName = false
    let toggle: () -> Void

    var body: some View {
        Button(title, systemImage: selection.isPinned(video) ? "pin.slash" : "pin", action: toggle)
            .disabled(!selection.canTogglePin(video))
    }

    private var title: String {
        let action = selection.isPinned(video) ? "Unpin" : "Pin"
        if !includeName {
            return "\(action) for Me"
        }
        let name = video.label ?? "Participant"
        let tile = video.isScreen ? "\(name)’s Screen" : name
        return "\(action) \(tile) for Me"
    }
}
