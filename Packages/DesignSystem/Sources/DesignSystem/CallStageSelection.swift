import ChatKit
import SwiftUI

enum CallViewLayout: String, CaseIterable, Identifiable {
    case automatic = "Automatic", tiled = "Tiled", spotlight = "Spotlight"
    var id: Self {
        self
    }
}

struct CallStageSelection {
    var layout = CallViewLayout.automatic
    var pinned: String?
    var hidesSelf = false
    var activeSpeaker: UUID?

    static func key(_ video: CallRemoteVideo) -> String {
        if let participant = video.participantID {
            return participant.uuidString + (video.isScreen ? "/screen" : "/camera")
        }
        return "slot/\(video.id)"
    }

    func main(in videos: [CallRemoteVideo]) -> CallRemoteVideo? {
        if let pinned, let video = videos.first(where: { Self.key($0) == pinned }) {
            return video
        }
        if layout == .spotlight {
            return videos.first(where: \.isScreen) ?? videos
                .first(where: { $0.participantID == activeSpeaker }) ?? videos.first
        }
        return CallStageLayout.main(of: videos)
    }

    func stage(in videos: [CallRemoteVideo]) -> CallStageLayout {
        if videos.isEmpty {
            return .none
        }
        if pinned.flatMap({ key in videos.first { Self.key($0) == key } }) != nil || layout == .spotlight {
            return videos.count == 1 ? .single : .presentation
        }
        if layout == .tiled {
            return .grid(columns: Int(Double(videos.count).squareRoot().rounded(.up)))
        }
        return CallStageLayout.of(videos)
    }

    /// Devices with no camera still have a place. Unassociated videos are kept
    /// without guessing their owners, and presentations never replace a camera.
    static func videos(_ videos: [CallRemoteVideo], roster: [CallRosterEntry]?) -> [CallRemoteVideo] {
        let cameras = Set(videos.filter { !$0.isScreen }.compactMap(\.participantID))
        let missing = (roster ?? []).filter { !cameras.contains($0.id) }
        return videos + missing.enumerated().map { index, entry in
            CallRemoteVideo(
                id: -2 - index, participantID: entry.id, label: entry.name, isScreen: false,
                content: AnyView(CallParticipantPlaceholder(name: entry.name))
            )
        }
    }
}

struct CallParticipantPlaceholder: View {
    let name: String
    var body: some View {
        ZStack {
            Color(white: 0.12)
            Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 88, height: 88)
                .background(.white.opacity(0.12), in: .circle)
                .accessibilityHidden(true)
        }
    }
}

struct CallLayoutMenu: View {
    @Binding var selection: CallStageSelection
    var videos: [CallRemoteVideo] = []
    var body: some View {
        Menu("Layout", systemImage: "rectangle.grid.2x2") {
            Picker("Layout", selection: $selection.layout) {
                ForEach(CallViewLayout.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Hide Self View", isOn: $selection.hidesSelf)
            if !videos.isEmpty {
                Menu("Pin", systemImage: "pin") {
                    ForEach(videos.filter { $0.participantID != nil }) { video in
                        Button(video.label ?? (video.isScreen ? "Shared screen" : "Participant")) {
                            selection.pinned = CallStageSelection.key(video)
                        }
                    }
                }
            }
            if selection.pinned != nil {
                Button("Unpin", systemImage: "pin.slash") { selection.pinned = nil }
            }
        }
    }
}
