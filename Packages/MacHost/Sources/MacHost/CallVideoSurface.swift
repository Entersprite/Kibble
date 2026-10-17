import AppKit
@preconcurrency import LiveKitWebRTC
import SwiftUI

struct CallVideoSurface: View {
    let controller: CallVideoController

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Color.black
                if controller.remoteVisible, let track = controller.remoteTrack {
                    NativeVideoView(track: track)
                        .accessibilityLabel(controller.remotePresentation ? "Shared screen" : "Remote camera")
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "video.slash").font(.largeTitle)
                        Text("Waiting for video").font(.callout)
                    }.foregroundStyle(.white.opacity(0.7))
                }
            }
            if controller.remoteVisible, controller.remotePresentation {
                Text("Shared screen").font(.caption.weight(.semibold))
                    .padding(8).background(.black.opacity(0.7), in: Capsule())
                    .foregroundStyle(.white).frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
                    .padding(12)
            }
            if controller.camera?.isOn == true, let track = controller.localTrack {
                NativeVideoView(track: track)
                    .scaleEffect(x: -1, y: 1)
                    .frame(width: 144, height: 108)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(12)
                    .accessibilityLabel("Your camera preview")
            }
        }
        .frame(height: 320)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Call video")
    }
}

private struct NativeVideoView: NSViewRepresentable {
    let track: LKRTCVideoTrack

    func makeNSView(context: Context) -> LKRTCMTLVideoView {
        let view = LKRTCMTLVideoView(frame: .zero)
        context.coordinator.attach(track, view: view)
        return view
    }

    func updateNSView(_ view: LKRTCMTLVideoView, context: Context) {
        context.coordinator.attach(track, view: view)
    }

    static func dismantleNSView(_ view: LKRTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(view)
        coordinator.track = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var track: LKRTCVideoTrack?
        func attach(_ next: LKRTCVideoTrack, view: LKRTCMTLVideoView) {
            guard track !== next else { return }
            track?.remove(view)
            track = next
            next.add(view)
        }
    }
}
