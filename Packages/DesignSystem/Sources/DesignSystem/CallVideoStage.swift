import ChatKit
import SwiftUI

/// Video renderers supplied by the host. The shared layout decides where each
/// one goes; the platform media engine draws inside them.
public struct CallVideoContent {
    /// The others' cameras and shared screens, each present only while showing.
    public var remotes: [CallRemoteVideo]
    /// Your own camera, present only while it is on.
    public var preview: AnyView?

    public init(remotes: [CallRemoteVideo] = [], preview: AnyView? = nil) {
        self.remotes = remotes
        self.preview = preview
    }

    /// One remote video, as a call with one person has.
    public init(remote: AnyView?, remoteIsScreen: Bool = false, preview: AnyView? = nil) {
        remotes = remote.map { [CallRemoteVideo(id: 0, isScreen: remoteIsScreen, content: $0)] } ?? []
        self.preview = preview
    }

    public var hasVideo: Bool {
        !remotes.isEmpty || preview != nil
    }
}

/// One remote video the host is rendering: a camera or a shared screen, from
/// one of its receiving slots. Present only while it is showing; a person
/// whose camera is off simply has no entry.
public struct CallRemoteVideo: Identifiable {
    /// The host's receiving slot, stable while the track is.
    public let id: Int
    /// The call-local device the video belongs to, when the provider said.
    public var participantID: UUID?
    public var label: String?
    public var isScreen: Bool
    public var content: AnyView

    public init(id: Int, participantID: UUID? = nil, label: String? = nil, isScreen: Bool, content: AnyView) {
        self.id = id
        self.participantID = participantID
        self.label = label
        self.isScreen = isScreen
        self.content = content
    }
}

/// How the stage arranges the remote videos it has.
enum CallStageLayout: Equatable {
    /// Nothing to show; the call's picture stays.
    case none
    /// One video fills the window, as a call with one person always has.
    case single
    /// A shared screen fills the window, every other video beside it.
    case presentation
    /// Cameras side by side, in this many columns.
    case grid(columns: Int)

    static func of(_ videos: [CallRemoteVideo]) -> Self {
        if videos.isEmpty {
            return .none
        }
        if videos.contains(where: \.isScreen) {
            return videos.count == 1 ? .single : .presentation
        }
        if videos.count == 1 {
            return .single
        }
        return .grid(columns: Int(Double(videos.count).squareRoot().rounded(.up)))
    }

    /// The video that fills the window, for the single and presentation
    /// layouts: the first shared screen, otherwise the only video.
    static func main(of videos: [CallRemoteVideo]) -> CallRemoteVideo? {
        switch of(videos) {
        case .single: videos.first
        case .presentation: videos.first(where: \.isScreen)
        case .none, .grid: nil
        }
    }

    /// Everything beside the main video in the presentation layout.
    static func alongside(_ videos: [CallRemoteVideo]) -> [CallRemoteVideo] {
        guard of(videos) == .presentation, let main = main(of: videos) else { return [] }
        return videos.filter { $0.id != main.id }
    }
}

/// The remote videos, laid out by `CallStageLayout`. The main video runs to
/// the window's edges; a grid keeps clear of the title and the controls.
struct CallVideoStage: View {
    let videos: [CallRemoteVideo]
    let roster: [CallRosterEntry]?
    /// Your own camera, which a grid takes as a tile of its own, so it covers
    /// nobody; the other layouts keep it in the corner.
    var preview: AnyView?
    /// Room the trailing column needs beside a shared screen, so the cameras
    /// sit next to it rather than over it.
    var trailingColumn: CGFloat = 0
    var selection = CallStageSelection()
    var pin: ((CallRemoteVideo) -> Void)?

    var body: some View {
        switch selection.stage(in: videos) {
        case .none:
            EmptyView()
        case .single:
            if let main = selection.main(in: videos) {
                focused(main)
                    .id(main.id)
            }
        case .presentation:
            if let main = selection.main(in: videos) {
                ZStack {
                    Color.black.ignoresSafeArea()
                    focused(main)
                        .padding(.trailing, trailingColumn)
                        .id(main.id)
                }
            }
        case .grid:
            grid(videos + ownTile)
        }
    }

    private func focused(_ video: CallRemoteVideo) -> some View {
        CallRemoteStage(content: video.content, isScreen: video.isScreen)
            .overlay(alignment: .bottomLeading) {
                if let name = video.label {
                    HStack(spacing: 5) {
                        if CallRoster.isMuted(video, in: roster) {
                            Image(systemName: "mic.slash.fill")
                        }
                        Text(name)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(8).background(.black.opacity(0.6), in: .capsule)
                    .padding(.leading, 16).padding(.bottom, 100)
                }
            }
    }

    private var ownTile: [CallRemoteVideo] {
        preview
            .map { [CallRemoteVideo(id: Self.ownTileID, label: "You", isScreen: false, content: $0)] } ?? []
    }

    /// Below every receiving slot, which counts up from zero.
    static let ownTileID = -1

    private func grid(_ videos: [CallRemoteVideo]) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            let columns = Int(Double(videos.count).squareRoot().rounded(.up))
            let rows = Int((Double(videos.count) / Double(columns)).rounded(.up))
            GeometryReader { proxy in
                let spacing: CGFloat = 8
                let width = (proxy.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
                let height = (proxy.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(width), spacing: spacing), count: columns),
                    spacing: spacing
                ) {
                    ForEach(videos) { video in
                        CallVideoTile(
                            video: video,
                            muted: CallRoster.isMuted(video, in: roster),
                            pin: video.participantID == nil ? nil : pin.map { action in { action(video) } },
                            isPinned: selection.pinned == CallStageSelection.key(video),
                            isSpeaking: roster?.first(where: { $0.id == video.participantID })?
                                .isSpeaking == true
                        )
                        .frame(width: width, height: max(0, height))
                    }
                }
            }
            // Clear of the title above and the controls below.
            .padding(.top, 44)
            .padding(.bottom, 88)
            .padding(.horizontal, 12)
            // The videos draw in platform views that keep mouse events, so a
            // clear layer above them is what lets a drag move the window.
            Color.clear.contentShape(Rectangle()).windowDragArea()
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }
}

/// One remote video in a grid or beside a shared screen, with its name and,
/// only when reported, a muted microphone.
struct CallVideoTile: View {
    let video: CallRemoteVideo
    var muted = false
    var cornerRadius: CGFloat = 14
    var pin: (() -> Void)?
    var isPinned = false
    var isSpeaking = false

    var body: some View {
        video.content
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isSpeaking ? Color.green : Color.white.opacity(0.16),
                        lineWidth: isSpeaking ? 2 : 1
                    )
            }
            .overlay(alignment: .bottomLeading) {
                if video.label != nil || muted || video.isScreen {
                    HStack(spacing: 4) {
                        if video.isScreen {
                            Image(systemName: "rectangle.on.rectangle")
                        }
                        if muted {
                            Image(systemName: "mic.slash.fill")
                        }
                        if let label = video.label {
                            Text(label).lineLimit(1)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: .capsule)
                    .padding(8)
                }
            }
            .contextMenu {
                if let pin {
                    Button(
                        isPinned ? "Unpin" : "Pin",
                        systemImage: isPinned ? "pin.slash" : "pin",
                        action: pin
                    )
                }
            }
            .accessibilityElement()
            .accessibilityLabel(CallVideoTile.label(for: video, muted: muted))
    }

    static func label(for video: CallRemoteVideo, muted: Bool) -> String {
        let name = video.label ?? "Participant"
        var label = video.isScreen ? "\(name)’s shared screen" : "\(name)’s camera"
        if muted {
            label += ", muted"
        }
        return label
    }
}

/// The videos beside a shared screen, in a column down the window's
/// trailing edge, under your own camera and screen when they show.
struct CallVideoFilmstrip: View {
    let videos: [CallRemoteVideo]
    let roster: [CallRosterEntry]?
    var width: CGFloat = 176
    var selection = CallStageSelection()
    var pin: ((CallRemoteVideo) -> Void)?

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 10) {
                ForEach(videos) { video in
                    CallVideoTile(
                        video: video,
                        muted: CallRoster.isMuted(video, in: roster),
                        pin: video.participantID == nil ? nil : pin.map { action in { action(video) } },
                        isPinned: selection.pinned == CallStageSelection.key(video),
                        isSpeaking: roster?.first(where: { $0.id == video.participantID })?.isSpeaking == true
                    )
                    .frame(width: width, height: (width * 9 / 16).rounded())
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                }
            }
        }
        .scrollIndicators(.never)
        .frame(width: width)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Other videos")
    }
}
