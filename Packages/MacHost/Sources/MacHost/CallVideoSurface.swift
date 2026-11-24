import AppKit
import DesignSystem
@preconcurrency import LiveKitWebRTC
import SwiftUI

/// The host's video renderers, handed to the shared call layout. The layout
/// reads which ones exist from this value; each renderer observes its own
/// track, so a new frame source does not rebuild the window's content.
@MainActor
enum CallVideoSurface {
    static func content(for controller: CallVideoController) -> CallVideoContent? {
        guard controller.camera != nil else { return nil }
        let preview = controller.camera?.isOn == true && controller.localTrack != nil
        return CallVideoContent(
            remotes: remotes(of: controller),
            preview: preview ? AnyView(LocalPreview(controller: controller, cropped: false)) : nil,
            croppedPreview: preview ? AnyView(LocalPreview(controller: controller, cropped: true)) : nil
        )
    }

    static func selfPreviewSize(video: CGSize, container: CGSize, cropped: Bool) -> CGSize {
        guard video.width > 0, video.height > 0, video.width.isFinite, video.height.isFinite
        else { return container }
        let widthScale = container.width / video.width
        let heightScale = container.height / video.height
        let scale = cropped ? max(widthScale, heightScale) : min(widthScale, heightScale)
        return CGSize(width: video.width * scale, height: video.height * scale)
    }

    /// Every remote video showing now, one per receiving slot, in the
    /// engine's order. An engine that reports no slots shows its one
    /// preferred video, as before several could be received.
    static func remotes(of controller: CallVideoController) -> [CallRemoteVideo] {
        let visible = controller.remoteVideos.filter(\.isVisible)
        guard !visible.isEmpty else {
            guard controller.remoteVisible, controller.remoteTrack != nil else { return [] }
            return [CallRemoteVideo(
                id: 0, isScreen: controller.remotePresentation,
                content: AnyView(RemoteVideo(controller: controller))
            )]
        }
        return visible.map { video in
            CallRemoteVideo(
                id: video.index, participantID: video.participantID, label: video.displayName,
                isScreen: video.isPresentation,
                content: AnyView(NativeVideoView(track: video.track)
                    .accessibilityLabel(video.isPresentation ? "Shared screen" : "Remote camera"))
            )
        }
    }

    /// What you are sharing, once capture has started.
    static func screen(for controller: CallVideoController) -> AnyView? {
        controller.screenSharing
            .preview == nil ? nil : AnyView(SharedScreen(sharing: controller.screenSharing))
    }
}

/// Not mirrored: a shared screen reads the same way for both people.
private struct SharedScreen: View {
    let sharing: CallScreenShareController

    var body: some View {
        if let track = sharing.preview {
            NativeVideoView(track: track)
        }
    }
}

private struct RemoteVideo: View {
    let controller: CallVideoController

    var body: some View {
        if let track = controller.remoteTrack {
            NativeVideoView(track: track)
                .accessibilityLabel(controller.remotePresentation ? "Shared screen" : "Remote camera")
        }
    }
}

/// Mirrored, the way a camera preview is shown everywhere on the Mac.
private struct LocalPreview: View {
    let controller: CallVideoController
    let cropped: Bool
    @State private var videoSize = CGSize.zero

    var body: some View {
        if let track = controller.localTrack {
            GeometryReader { proxy in
                let display = CallVideoSurface.selfPreviewSize(
                    video: videoSize, container: proxy.size, cropped: cropped
                )
                NativeVideoView(track: track, reportSize: { videoSize = $0 })
                    .frame(width: display.width, height: display.height)
                    .scaleEffect(x: -1, y: 1)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
        }
    }
}

private struct NativeVideoView: NSViewRepresentable {
    let track: LKRTCVideoTrack
    var reportSize: (@MainActor @Sendable (CGSize) -> Void)?

    func makeNSView(context: Context) -> LKRTCMTLVideoView {
        let view = LKRTCMTLVideoView(frame: .zero)
        if reportSize != nil {
            view.delegate = context.coordinator
        }
        context.coordinator.attach(track, view: view)
        return view
    }

    func updateNSView(_ view: LKRTCMTLVideoView, context: Context) {
        context.coordinator.attach(track, view: view)
    }

    static func dismantleNSView(_ view: LKRTCMTLVideoView, coordinator: Coordinator) {
        view.delegate = nil
        coordinator.track?.remove(view)
        coordinator.track = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(reportSize: reportSize)
    }

    final class Coordinator: NSObject, LKRTCVideoViewDelegate {
        private let reportSize: (@MainActor @Sendable (CGSize) -> Void)?
        var track: LKRTCVideoTrack?

        init(reportSize: (@MainActor @Sendable (CGSize) -> Void)?) {
            self.reportSize = reportSize
        }

        func videoView(_: any LKRTCVideoRenderer, didChangeVideoSize size: CGSize) {
            guard let reportSize else { return }
            Task { @MainActor in reportSize(size) }
        }

        func attach(_ next: LKRTCVideoTrack, view: LKRTCMTLVideoView) {
            guard track !== next else { return }
            track?.remove(view)
            track = next
            next.add(view)
        }
    }
}
