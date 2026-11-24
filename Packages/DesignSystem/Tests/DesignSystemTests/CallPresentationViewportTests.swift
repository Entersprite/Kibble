import AppKit
import ChatKit
import SwiftUI
import Testing
@testable import DesignSystem

@MainActor
struct CallPresentationViewportTests {
    @Test func zoomUsesTheGestureAnchorAndPanRemainsBoundedAcrossResizes() {
        var viewport = CallPresentationViewportState()
        let window = CGSize(width: 400, height: 200)
        viewport.zoom(by: 2, around: .topLeading)
        #expect(viewport.scale == 2)
        #expect(viewport.offset(in: window) == CGSize(width: 200, height: 100))
        viewport.pan(by: CGSize(width: -50, height: -200), in: window)
        #expect(viewport.offset(in: window) == CGSize(width: 150, height: -100))
        #expect(viewport.offset(in: CGSize(width: 200, height: 400)) == CGSize(width: 75, height: -200))
        viewport.zoom(by: 100)
        #expect(viewport.scale == CallPresentationViewportState.maximumScale)
        viewport.zoom(by: .nan)
        #expect(viewport.scale == CallPresentationViewportState.maximumScale)
        viewport.zoom(by: 0.1)
        #expect(!viewport.isZoomed)
        #expect(viewport.offset(in: window) == .zero)
    }

    @Test func enlargementKeepsTheFilmstripAndRestoresThePinnedLayout() {
        let camera = CallParticipantDevice(id: UUID(), isPinnedForEveryone: true)
        let screen = CallParticipantDevice(id: UUID(), isPresentation: true)
        let cameraTile = video(0, participant: camera)
        let screenTile = video(1, participant: screen)
        let videos = [cameraTile, screenTile]
        var selection = CallStageSelection(layoutPreferences: .init(layout: .spotlight))
        selection.observeParticipants([camera, screen])
        let preferences = selection.receivePreferences

        selection.toggleEnlargedPresentation(cameraTile)
        #expect(!selection.presentationIsEnlarged(in: videos))
        selection.toggleEnlargedPresentation(screenTile)
        #expect(selection.stage(in: videos) == .presentation)
        #expect(selection.main(in: videos)?.participantID == screen.id)
        #expect(selection.filmstrip(in: videos).map(\.participantID) == [camera.id])
        #expect(selection.receivePreferences == preferences)
        #expect(selection.layoutPreferences.layout == .spotlight)
        selection.observeParticipants(nil)
        #expect(selection.presentationIsEnlarged(in: videos))
        selection.toggleEnlargedPresentation(screenTile)
        #expect(selection.stage(in: videos) == .single)
        #expect(selection.main(in: videos)?.participantID == camera.id)

        selection.toggleEnlargedPresentation(screenTile)
        selection.layoutPreferences.layout = .tiled
        #expect(selection.enlargedPresentation == nil)
        #expect(selection.main(in: videos)?.participantID == camera.id)

        selection.toggleEnlargedPresentation(screenTile)
        selection.toggleVideoFeed(screen.id)
        #expect(selection.enlargedPresentation == nil)
        selection.toggleVideoFeed(screen.id)
        selection.toggleEnlargedPresentation(screenTile)
        selection.observeParticipants([camera])
        #expect(selection.enlargedPresentation == nil)
    }

    @Test func zoomedPresentationRendersWithinTheNativeViewport() throws {
        let source = CallParticipantDevice(id: UUID(), isPresentation: true)
        var selection = CallStageSelection()
        selection.observeParticipants([source])
        var viewport = CallPresentationViewportState()
        viewport.zoom(by: 2, around: .topLeading)
        var screen = video(0, participant: source)
        screen.content = AnyView(VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.red
                Color.green
            }
            HStack(spacing: 0) {
                Color.yellow
                Color.blue
            }
        })
        let content = CallPresentationViewport(
            video: screen, selection: .constant(selection), viewport: viewport
        ).frame(width: 400, height: 240)
        let host = NSHostingView(rootView: content)
        host.frame.size = host.fittingSize
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(host.frame.size == CGSize(width: 400, height: 240))
        let sample = bitmap.colorAt(x: bitmap.pixelsWide - 20, y: bitmap.pixelsHigh - 20)
        let corner = try #require(sample?.usingColorSpace(.deviceRGB))
        #expect(corner.redComponent > 0.7)
        #expect(corner.blueComponent < 0.3)
        if let output = ProcessInfo.processInfo.environment["KIBBLE_MEET_ZOOM_RENDER"] {
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output))
        }
    }

    private func video(_ id: Int, participant: CallParticipantDevice) -> CallRemoteVideo {
        CallRemoteVideo(
            id: id, participantID: participant.id, label: "Participant",
            isScreen: participant.isPresentation, content: AnyView(Color.black)
        )
    }
}
