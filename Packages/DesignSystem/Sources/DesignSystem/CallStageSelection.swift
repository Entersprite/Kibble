import ChatKit
import SwiftUI

struct CallVideoPreferenceUpdate: Equatable {
    let call: UUID
    let media: UUID?
    let preferences: CallVideoPreferences
}

struct CallStageSelection {
    static let pinLimit = 6

    struct Tile: Hashable {
        let device: UUID
        let isScreen: Bool

        init?(_ video: CallRemoteVideo) {
            guard let device = video.participantID else { return nil }
            self.device = device
            isScreen = video.isScreen
        }
    }

    var layoutPreferences: CallLayoutPreferences {
        didSet {
            if layoutPreferences.layout != oldValue.layout {
                enlargedPresentation = nil
            }
            if layoutPreferences.selfView.placement != oldValue.selfView.placement {
                minimizesSelf = false
            }
        }
    }

    var hidesSelf = false
    var minimizesSelf = false
    var supportsSelfCrop = false
    var activeSpeaker: UUID?
    private(set) var personalPins: [Tile] = []
    private var participantIDs: Set<UUID>?
    private var sharedPins: Set<UUID> = []
    private var dismissedSharedPins: Set<UUID> = []
    private(set) var hiddenVideoFeeds: Set<UUID> = []
    private(set) var remoteVideoFeeds: [CallParticipantDevice] = []
    private(set) var enlargedPresentation: UUID?

    init(layoutPreferences: CallLayoutPreferences = CallLayoutPreferences()) {
        self.layoutPreferences = layoutPreferences
    }

    mutating func observeParticipants(_ participants: [CallParticipantDevice]?) {
        guard let participants else { return }
        if let speaker = participants
            .first(where: { !$0.isLocal && !$0.isPresentation && $0.isSpeaking == true }) {
            activeSpeaker = speaker.id
        }
        let devices = Set(participants.map(\.id))
        participantIDs = devices
        remoteVideoFeeds = participants.filter { !$0.isLocal }
        hiddenVideoFeeds.formIntersection(remoteVideoFeeds.map(\.id))
        if let enlargedPresentation,
           !remoteVideoFeeds.contains(where: { $0.id == enlargedPresentation && $0.isPresentation }) {
            self.enlargedPresentation = nil
        }
        sharedPins = Set(participants.filter { !$0.isLocal && $0.isPinnedForEveryone == true }.map(\.id))
        dismissedSharedPins.formIntersection(
            participants.filter { $0.isPinnedForEveryone != false }.map(\.id)
        )
        personalPins.removeAll { !devices.contains($0.device) }
        let shared = visibleSharedPins
        while pinCount > Self.pinLimit,
              let index = personalPins.lastIndex(where: { !shared.contains($0.device) }) {
            personalPins.remove(at: index)
        }
    }

    private var visibleSharedPins: Set<UUID> {
        sharedPins.subtracting(dismissedSharedPins)
    }

    var receivePreferences: CallVideoPreferences {
        CallVideoPreferences(
            personalPins: personalPins.map(\.device),
            dismissedSharedPins: dismissedSharedPins,
            hiddenVideoFeeds: hiddenVideoFeeds
        )
    }

    var pinCount: Int {
        let shared = visibleSharedPins
        return shared.count + personalPins.filter { !shared.contains($0.device) }.count
    }

    func isSharedPin(_ video: CallRemoteVideo) -> Bool {
        guard let id = video.participantID else { return false }
        return sharedPins.contains(id) && !dismissedSharedPins.contains(id)
    }

    func isPinned(_ video: CallRemoteVideo) -> Bool {
        isSharedPin(video) || Tile(video).map(personalPins.contains) == true
    }

    func canTogglePin(_ video: CallRemoteVideo) -> Bool {
        guard let tile = Tile(video), participantIDs?.contains(tile.device) != false else { return false }
        return isPinned(video) || pinCount < Self.pinLimit
    }

    mutating func togglePin(_ video: CallRemoteVideo) {
        guard let tile = Tile(video), canTogglePin(video) else { return }
        if isSharedPin(video) {
            dismissedSharedPins.insert(tile.device)
            personalPins.removeAll { $0 == tile }
        } else if let index = personalPins.firstIndex(of: tile) {
            personalPins.remove(at: index)
        } else {
            personalPins.append(tile)
        }
    }

    func primaryVideos(in videos: [CallRemoteVideo]) -> [CallRemoteVideo] {
        if let enlarged = enlargedVideo(in: videos) {
            return [enlarged]
        }
        let shared = videos.filter(isSharedPin)
        let personal = personalPins.compactMap { tile in
            videos.first { Tile($0) == tile && !isSharedPin($0) }
        }
        let pinned = shared + personal
        if !pinned.isEmpty {
            return Array(pinned.prefix(Self.pinLimit))
        }
        if layoutPreferences.layout == .spotlight || layoutPreferences.layout == .sidebar {
            let speaker = activeSpeaker.flatMap { id in videos.first { $0.participantID == id } }
            let main = videos.first(where: \.isScreen) ?? speaker ?? videos.first
            return main.map { [$0] } ?? []
        }
        return CallStageLayout.main(of: videos).map { [$0] } ?? []
    }

    func main(in videos: [CallRemoteVideo]) -> CallRemoteVideo? {
        primaryVideos(in: videos).first
    }

    func stage(in videos: [CallRemoteVideo]) -> CallStageLayout {
        if videos.isEmpty {
            return .none
        }
        if enlargedVideo(in: videos) != nil {
            return videos.count == 1 ? .single : .presentation
        }
        if layoutPreferences.layout == .spotlight {
            return primaryVideos(in: videos).count > 1 ? .focusGrid : .single
        }
        if videos.contains(where: isPinned) || layoutPreferences.layout == .sidebar {
            return videos.count == 1 ? .single : .presentation
        }
        if layoutPreferences.layout == .tiled {
            let count = min(videos.count, layoutPreferences.tileLimit.rawValue)
            return .grid(columns: Int(Double(count).squareRoot().rounded(.up)))
        }
        return CallStageLayout.of(videos)
    }

    func filmstrip(in videos: [CallRemoteVideo]) -> [CallRemoteVideo] {
        guard stage(in: videos) == .presentation else { return [] }
        let stageIDs = Set(primaryVideos(in: videos).map(\.id))
        return videos.filter { !stageIDs.contains($0.id) }
    }

    func gridVideos(_ videos: [CallRemoteVideo], ownTile: CallRemoteVideo?) -> [CallRemoteVideo] {
        let local = ownTile.map { [$0] } ?? []
        let ordered = videos.filter(\.handRaised) + videos.filter { !$0.handRaised }
        guard layoutPreferences.layout == .tiled else { return ordered + local }
        let limit = layoutPreferences.tileLimit.rawValue - local.count
        let displayed = ordered.prefix(limit)
        if layoutPreferences.hidesTilesWithoutVideo,
           let speaker = ordered.dropFirst(limit).first(where: isCameraOffSpeaker) {
            return Array(displayed.dropLast()) + [speaker] + local
        }
        return Array(displayed) + local
    }

    func selfViewSurface(in videos: [CallRemoteVideo]) -> CallSelfViewSurface {
        guard !hidesSelf else { return .hidden }
        if minimizesSelf {
            return .minimized
        }
        let placement = layoutPreferences.selfView.placement
        guard placement != .floating else { return .floating }
        switch stage(in: videos) {
        case .grid:
            return .grid
        case .presentation where placement == .tile:
            return .filmstrip
        case .single where placement == .tile && layoutPreferences.layout == .automatic:
            if let video = videos.first, !video.isScreen, !isPinned(video) {
                return .grid
            }
            return .floating
        default:
            return .floating
        }
    }

    func visibleVideos(from candidates: [CallRemoteVideo]) -> [CallRemoteVideo] {
        candidates.filter {
            guard !isVideoFeedHidden($0) else { return false }
            if !$0.isPlaceholder || isPinned($0) {
                return true
            }
            return !$0.isScreen && (!layoutPreferences.hidesTilesWithoutVideo || isCameraOffSpeaker($0))
        }
    }

    private func isCameraOffSpeaker(_ video: CallRemoteVideo) -> Bool {
        video.isPlaceholder && !video.isScreen && videoFeed(for: video)?.isSpeaking == true
    }

    func videoFeed(for video: CallRemoteVideo) -> CallParticipantDevice? {
        remoteVideoFeeds.first { $0.id == video.participantID && $0.isPresentation == video.isScreen }
    }

    private func isVideoFeedHidden(_ video: CallRemoteVideo) -> Bool {
        guard let id = video.participantID, hiddenVideoFeeds.contains(id) else { return false }
        return videoFeed(for: video) != nil
    }

    mutating func toggleVideoFeed(_ id: UUID) {
        guard remoteVideoFeeds.contains(where: { $0.id == id }) else { return }
        if hiddenVideoFeeds.remove(id) == nil {
            hiddenVideoFeeds.insert(id)
            if enlargedPresentation == id {
                enlargedPresentation = nil
            }
        }
    }

    func canEnlarge(_ video: CallRemoteVideo) -> Bool {
        guard video.isScreen, !video.isPlaceholder, let id = video.participantID else { return false }
        return participantIDs?.contains(id) != false && !hiddenVideoFeeds.contains(id)
    }

    mutating func toggleEnlargedPresentation(_ video: CallRemoteVideo) {
        guard canEnlarge(video), let id = video.participantID else { return }
        enlargedPresentation = enlargedPresentation == id ? nil : id
    }

    func presentationIsEnlarged(in videos: [CallRemoteVideo]) -> Bool {
        enlargedVideo(in: videos) != nil
    }

    private func enlargedVideo(in videos: [CallRemoteVideo]) -> CallRemoteVideo? {
        guard let enlargedPresentation else { return nil }
        return videos.first { $0.participantID == enlargedPresentation && canEnlarge($0) }
    }

    /// Devices with no camera still have a place. Unassociated videos are kept
    /// without guessing their owners, and presentations never replace a camera.
    static func videos(
        _ videos: [CallRemoteVideo], roster: [CallRosterEntry]?, participants: [CallParticipantDevice]? = nil
    ) -> [CallRemoteVideo] {
        let cameras = Set(videos.filter { !$0.isScreen }.compactMap(\.participantID))
        let screens = Set(videos.filter(\.isScreen).compactMap(\.participantID))
        let missing = (roster ?? []).filter { !cameras.contains($0.id) }
        let presentations = (participants ?? []).filter {
            $0.isPresentation && !$0.isLocal && !screens.contains($0.id)
        }
        let placeholders = missing.map { ($0.id, $0.name, false) }
            + presentations.map { ($0.id, CallRoster.name(of: $0), true) }
        let joinedTiles = videos + placeholders.enumerated().map { index, tile in
            CallRemoteVideo(
                id: -2 - index, participantID: tile.0, label: tile.1, isScreen: tile.2,
                content: AnyView(CallParticipantPlaceholder(name: tile.1)), isPlaceholder: true
            )
        }
        let raised = Set((participants ?? [])
            .filter { !$0.isLocal && !$0.isPresentation && $0.handRaised == true }
            .map(\.id))
        return joinedTiles.map { tile in
            var tile = tile
            tile.handRaised = !tile.isScreen && tile.participantID.map(raised.contains) == true
            return tile
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
    var save: ((CallLayoutPreferences) -> Void)?

    var body: some View {
        Menu("Layout", systemImage: "rectangle.grid.2x2") {
            // The arrangement first, checked in place as a menu's choices
            // are; then what is left out of it, your own picture, and last
            // the pins and feeds that are yours alone.
            Picker("Layout", selection: settings.layout) {
                ForEach(CallViewLayout.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if selection.layoutPreferences.layout == .tiled {
                Picker("Maximum Tiles", selection: settings.tileLimit) {
                    ForEach(CallTileLimit.allCases) { Text("\($0.rawValue) Tiles").tag($0) }
                }
                .pickerStyle(.menu)
            }
            Divider()
            Toggle("Hide Tiles Without Video", isOn: settings.hidesTilesWithoutVideo)
            Toggle("Hide My Video", isOn: $selection.hidesSelf)
            Menu("Self View", systemImage: "person.crop.rectangle") {
                let visibleVideos = selection.visibleVideos(from: videos)
                CallSelfViewControls(
                    selection: $selection, save: save,
                    isFloating: selection.selfViewSurface(in: visibleVideos).isFloating
                )
            }
            .disabled(selection.hidesSelf)
            Divider()
            CallPersonalVideoControls(selection: $selection, videos: videos)
        }
    }

    private var settings: Binding<CallLayoutPreferences> {
        Binding(get: { selection.layoutPreferences }, set: {
            selection.layoutPreferences = $0
            save?($0)
        })
    }
}
