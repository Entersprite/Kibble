import AppKit
import ChatKit
import SwiftUI
import Testing
@testable import DesignSystem

@MainActor
struct CallLayoutTests {
    @Test func spotlightFillsTheStageAndSidebarKeepsTheOtherTiles() {
        let activeSpeaker = UUID()
        let first = video(0), speaker = video(1, owner: activeSpeaker), screen = video(2, screen: true)
        let cameras = [first, speaker]
        let withScreen = cameras + [screen]
        var selection = CallStageSelection(layoutPreferences: .init(layout: .spotlight))
        selection.activeSpeaker = activeSpeaker
        #expect(selection.main(in: cameras)?.id == speaker.id)
        #expect(selection.main(in: withScreen)?.id == screen.id)
        #expect(selection.stage(in: withScreen) == .single)
        #expect(selection.filmstrip(in: withScreen).isEmpty)

        selection.layoutPreferences.layout = .sidebar
        #expect(selection.main(in: cameras)?.id == speaker.id)
        #expect(selection.main(in: withScreen)?.id == screen.id)
        #expect(selection.stage(in: withScreen) == .presentation)
        #expect(selection.filmstrip(in: withScreen).map(\.id) == [first.id, speaker.id])
    }

    @Test func spotlightKeepsSharedAndPersonalPinsTogetherWithoutTheFilmstrip() {
        let sharedID = UUID(), personalID = UUID()
        let shared = video(0, owner: sharedID), personal = video(1, owner: personalID)
        let screen = video(2, screen: true), visible = [shared, personal, screen]
        var selection = CallStageSelection(layoutPreferences: .init(layout: .spotlight))
        selection.observeParticipants([
            CallParticipantDevice(id: sharedID, isPinnedForEveryone: true),
            CallParticipantDevice(id: personalID)
        ])
        selection.togglePin(personal)
        #expect(selection.stage(in: visible) == .focusGrid)
        #expect(selection.primaryVideos(in: visible).map(\.id) == [shared.id, personal.id])
        #expect(selection.filmstrip(in: visible).isEmpty)

        selection.toggleVideoFeed(sharedID)
        let filtered = selection.visibleVideos(from: visible)
        #expect(selection.stage(in: filtered) == .single)
        #expect(selection.main(in: filtered)?.id == personal.id)
    }

    @Test func tiledLimitIncludesTheSelfTileAndTheVideoFilterRespectsPins() throws {
        let cameraOff = CallParticipantDevice(id: UUID(), displayName: "Taylor")
        let roster = CallRoster.entries([cameraOff])
        let cameras = (0 ..< 8).map { video($0) }
        let candidates = CallStageSelection.videos(cameras, roster: roster)
        let placeholder = try #require(candidates.last)
        let ownTile = video(CallVideoStage.ownTileID)
        var selection = CallStageSelection(layoutPreferences: .init(layout: .tiled, tileLimit: .four))
        #expect(selection.visibleVideos(from: candidates).count == 9)
        #expect(selection.stage(in: candidates) == .grid(columns: 2))
        #expect(selection.gridVideos(cameras, ownTile: nil).map(\.id) == [0, 1, 2, 3])
        #expect(selection.gridVideos(cameras, ownTile: ownTile).map(\.id) == [0, 1, 2, ownTile.id])
        selection.layoutPreferences.hidesTilesWithoutVideo = true
        #expect(selection.visibleVideos(from: candidates).map(\.id) == cameras.map(\.id))
        selection.observeParticipants([CallParticipantDevice(id: cameraOff.id, isSpeaking: true)])
        let speaking = selection.visibleVideos(from: candidates)
        #expect(speaking.contains { $0.id == placeholder.id })
        #expect(selection.gridVideos(speaking, ownTile: ownTile).map(\.id) == [
            0,
            1,
            placeholder.id,
            ownTile.id
        ])
        selection.observeParticipants([cameraOff])
        #expect(!selection.visibleVideos(from: candidates).contains { $0.id == placeholder.id })
        selection.togglePin(placeholder)
        let visible = selection.visibleVideos(from: candidates)
        #expect(selection.main(in: visible)?.id == placeholder.id)
        #expect(selection.stage(in: visible) == .presentation)
    }

    @Test(arguments: [CallViewLayout.spotlight, .sidebar])
    func spotlightAndSidebarRenderInTheNativeCallView(_ layout: CallViewLayout) throws {
        var actions = AudioCallActions(accept: {}, decline: {}, toggleMute: {}, hangUp: {})
        actions.layoutPreferences = CallLayoutPreferences(layout: layout, hidesTilesWithoutVideo: true)
        let call = AudioCallSession(ConversationCallSnapshot(
            id: UUID(), target: .init(conversationID: .init("demo"), displayName: "Design"),
            phase: .connected
        ))
        let stage = AudioCallView(
            call: call, actions: actions,
            video: CallVideoContent(remotes: [video(0), video(1, screen: true), video(2)])
        ).frame(width: 760, height: 480)
        let host = NSHostingView(rootView: stage)
        host.frame.size = host.fittingSize
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(host.frame.width == 760)
        #expect(host.frame.height == 480)
        if let output = ProcessInfo.processInfo.environment["KIBBLE_CALL_LAYOUT_RENDER_DIR"] {
            let url = URL(fileURLWithPath: output).appending(path: layout.rawValue + ".png")
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        }
    }

    private func video(_ id: Int, screen: Bool = false, owner: UUID? = nil) -> CallRemoteVideo {
        CallRemoteVideo(
            id: id, participantID: owner, label: screen ? "Shared screen" : "Camera \(id)",
            isScreen: screen, content: AnyView(screen ? Color.blue : Color.purple)
        )
    }
}
