import AppKit
import ChatKit
import SwiftUI
import Testing
@testable import DesignSystem

@MainActor
struct CallSelfViewTests {
    @Test func existingLayoutPreferencesDecodeWithAnAutomaticSelfView() throws {
        let data = Data(#"{"layout":"sidebar","tileLimit":9,"hidesTilesWithoutVideo":true}"#.utf8)
        let preferences = try JSONDecoder().decode(CallLayoutPreferences.self, from: data)
        #expect(preferences == CallLayoutPreferences(
            layout: .sidebar,
            tileLimit: .nine,
            hidesTilesWithoutVideo: true
        ))
    }

    @Test func selfViewPlacementSupportsOnePeerAndKeepsSpotlightSeparate() {
        let camera = cameraVideo()
        let screen = CallRemoteVideo(id: 1, isScreen: true, content: AnyView(Color.blue))
        var selection = CallStageSelection()
        #expect(selection.selfViewSurface(in: [camera]) == .floating)
        #expect(selection.selfViewSurface(in: [camera, cameraVideo(id: 2)]) == .grid)
        selection.layoutPreferences.selfView.placement = .tile
        #expect(selection.selfViewSurface(in: [camera]) == .grid)
        #expect(selection.selfViewSurface(in: [camera, screen]) == .filmstrip)
        selection.layoutPreferences.layout = .spotlight
        #expect(selection.selfViewSurface(in: [camera, screen]) == .floating)
        selection.minimizesSelf = true
        #expect(selection.selfViewSurface(in: [camera, screen]) == .minimized)
        selection.layoutPreferences.selfView.placement = .floating
        #expect(selection.selfViewSurface(in: [camera, screen]) == .floating)
        selection.hidesSelf = true
        #expect(selection.selfViewSurface(in: [camera, screen]) == .hidden)
        #expect(selection.receivePreferences == CallVideoPreferences())
    }

    @Test(arguments: [
        (CGPoint(x: 2, y: 2), CallSelfViewPreferences.Corner.topLeading),
        (CGPoint(x: 300, y: 1), .topTrailing),
        (CGPoint(x: 280, y: 190), .bottomTrailing),
        (CGPoint(x: 2, y: 250), .bottomLeading)
    ])
    func aDraggedPreviewSnapsToTheNearestCorner(_ point: CGPoint, _ corner: CallSelfViewPreferences.Corner) {
        #expect(CallSelfViewPreferences.Corner
            .nearest(to: point, in: CGSize(width: 320, height: 200)) == corner)
    }

    @Test(arguments: [CallSelfViewPreferences.Placement.floating, .tile])
    func twoPersonCallRendersBothSelfViewPlacements(_ placement: CallSelfViewPreferences.Placement) throws {
        let call = AudioCallSession(ConversationCallSnapshot(
            id: UUID(), target: .init(conversationID: .init("demo"), displayName: "Kibble call"),
            phase: .connected
        ))
        var actions = AudioCallActions(accept: {}, decline: {}, toggleMute: {}, hangUp: {})
        actions.layoutPreferences.selfView = CallSelfViewPreferences(
            placement: placement, corner: .bottomLeading, cropped: true
        )
        let content = AudioCallView(
            call: call, actions: actions,
            video: CallVideoContent(
                remotes: [cameraVideo()],
                preview: AnyView(Color.yellow),
                croppedPreview: AnyView(Color.green)
            )
        ).frame(width: 760, height: 480)
        let host = NSHostingView(rootView: content)
        host.frame.size = host.fittingSize
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(host.frame.size == CGSize(width: 760, height: 480))
        if let output = ProcessInfo.processInfo.environment["KIBBLE_SELF_VIEW_RENDER_DIR"] {
            let url = URL(fileURLWithPath: output).appending(path: placement.rawValue + ".png")
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        }
    }

    private func cameraVideo(id: Int = 0) -> CallRemoteVideo {
        CallRemoteVideo(id: id, label: "Camera", isScreen: false, content: AnyView(Color.purple))
    }
}
