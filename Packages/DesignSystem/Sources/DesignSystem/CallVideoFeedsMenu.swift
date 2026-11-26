import ChatKit
import SwiftUI

struct CallPersonalVideoControls: View {
    @Binding var selection: CallStageSelection
    let videos: [CallRemoteVideo]

    var body: some View {
        CallPersonalPinsMenu(selection: $selection, videos: videos)
        if !selection.remoteVideoFeeds.isEmpty {
            let labels = CallRoster.disambiguatedNames(in: selection.remoteVideoFeeds)
            Menu("Video Feeds", systemImage: "video") {
                ForEach(selection.remoteVideoFeeds, id: \.id) { participant in
                    CallVideoFeedButton(
                        participant: participant, selection: $selection,
                        targetName: labels[participant.id] ?? CallRoster.name(of: participant)
                    )
                }
            }
        }
    }
}

struct CallVideoTileMenu: View {
    let video: CallRemoteVideo
    @Binding var selection: CallStageSelection

    var body: some View {
        if selection.canEnlarge(video) {
            CallEnlargePresentationButton(video: video, selection: $selection)
        }
        if video.participantID != nil {
            CallPersonalPinButton(video: video, selection: selection) { selection.togglePin(video) }
        }
        if let participant = selection.videoFeed(for: video) {
            CallVideoFeedButton(participant: participant, selection: $selection)
        }
    }
}

struct CallEnlargePresentationButton: View {
    let video: CallRemoteVideo
    @Binding var selection: CallStageSelection

    var body: some View {
        let enlarged = selection.enlargedPresentation == video.participantID
        let symbol = enlarged ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        Button(enlarged ? "Restore Layout" : "Enlarge Presentation", systemImage: symbol) {
            selection.toggleEnlargedPresentation(video)
        }
    }
}

private struct CallVideoFeedButton: View {
    let participant: CallParticipantDevice
    @Binding var selection: CallStageSelection
    var targetName: String?

    var body: some View {
        let hidden = selection.hiddenVideoFeeds.contains(participant.id)
        Button(title(hidden: hidden), systemImage: hidden ? "video" : "video.slash") {
            selection.toggleVideoFeed(participant.id)
        }
    }

    private func title(hidden: Bool) -> String {
        let action = hidden ? "Start Watching" : "Don’t Watch"
        guard let name = targetName else { return action }
        return participant.isPresentation ? "\(action) \(name)’s Presentation" : "\(action) \(name)"
    }
}
