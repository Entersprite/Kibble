import AppKit
import ChatKit
import DesignSystem
import Foundation
@preconcurrency import LiveKitWebRTC
import Testing
@testable import MacHost

/// The call window in and out of full screen. The transitions are driven by
/// the delegate calls AppKit makes, with the frames it sets, because a test
/// cannot take over the screen.
@MainActor
struct AudioCallWindowFullScreenTests {
    private let actions = AudioCallActions(accept: {}, decline: {}, toggleMute: {}, hangUp: {})

    @Test func theAudioSizeCanGoFullScreenAndTheStageFillsIt() throws {
        let host = AudioCallWindowHost(actions: { _ in actions }, windowClosed: { _ in }, present: { _ in })
        host.update(call: call(phase: .connected), windowRequests: 1)
        let window = try #require(host.window)
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(!window.styleMask.contains(.resizable))
        #expect(window.standardWindowButton(.zoomButton)?.isEnabled == true)
        // The hosting view hands the stage's largest size to the window, and
        // full screen keeps within it: a compact maximum would leave a strip.
        window.layoutIfNeeded()
        #expect(window.contentMaxSize.width > 5000)
        #expect(window.contentMaxSize.height > 5000)
        // AppKit fills the screen only with a resizable window: lent for full
        // screen, taken back with the audio size on the way out.
        let compact = window.frame
        host.windowWillEnterFullScreen(notification(window))
        #expect(window.styleMask.contains(.resizable))
        host.windowDidEnterFullScreen(notification(window))
        host.windowWillExitFullScreen(notification(window))
        host.windowDidExitFullScreen(notification(window))
        #expect(!window.styleMask.contains(.resizable))
        #expect(window.frame == compact)
        host.update(call: nil, windowRequests: 1)
    }

    @Test func aLayoutChangeWhileFullScreenResizesTheWindowWhenItLeaves() async throws {
        var fullScreen = false
        let host = AudioCallWindowHost(
            actions: { _ in actions }, windowClosed: { _ in }, isFullScreen: { _ in fullScreen },
            present: { _ in }
        )
        let connected = call(phase: .connected)
        host.update(call: connected, windowRequests: 1)
        let window = try #require(host.window)
        let compact = window.frame
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        func enterFullScreen() {
            host.windowWillEnterFullScreen(notification(window))
            fullScreen = true
            window.setFrame(screen, display: true)
            host.windowDidEnterFullScreen(notification(window))
        }
        /// AppKit puts back the frame from before full screen, then tells the host.
        func exitFullScreen(to frame: NSRect) {
            host.windowWillExitFullScreen(notification(window))
            fullScreen = false
            window.setFrame(frame, display: true)
            host.windowDidExitFullScreen(notification(window))
        }
        enterFullScreen()
        // The camera comes on while full screen: the screen keeps the frame.
        let video = try await cameraOn()
        host.update(call: connected, windowRequests: 1, video: video)
        #expect(host.layout.isVideo)
        #expect(window.frame == screen)
        exitFullScreen(to: compact)
        #expect(window.frame.size == CallLayout.video)
        #expect(window.styleMask.contains(.resizable))
        #expect(window.contentMinSize == CallLayout.videoMinimum)
        // An audio call that begins while full screen gets the audio size back.
        let videoFrame = window.frame
        enterFullScreen()
        host.update(call: call(phase: .connecting), windowRequests: 2)
        #expect(!host.layout.isVideo)
        #expect(window.frame == screen)
        exitFullScreen(to: videoFrame)
        #expect(window.frame.width == CallLayout.compact.width)
        #expect(!window.styleMask.contains(.resizable))
        // The hosting view keeps the audio stage's own minimum here.
        #expect(window.contentMinSize.width < CallLayout.videoMinimum.width)
        video.clear()
        host.update(call: nil, windowRequests: 2)
    }

    private func call(phase: AudioCallPhase) -> AudioCallSession {
        AudioCallSession(AudioCallSnapshot(
            id: UUID(),
            recipient: AudioCallRecipient(
                conversationID: Conversation.ID("dm-test"), memberID: Member.ID("peer"),
                displayName: "Maya"
            ),
            direction: .outgoing,
            phase: phase
        ))
    }

    private func notification(_ window: NSWindow) -> Notification {
        Notification(name: NSWindow.didEnterFullScreenNotification, object: window)
    }

    /// A camera that is on, with a real local track, so the window's video
    /// layout is the one a call gets.
    private func cameraOn() async throws -> CallVideoController {
        LKRTCInitializeSSL()
        let factory = LKRTCPeerConnectionFactory()
        let video = CallVideoController()
        let track = factory.videoTrack(with: factory.videoSource(), trackId: "camera")
        _ = video.install(CameraRoute(), local: track)
        video.turnOn()
        for _ in 0 ..< 400 where video.camera?.isOn != true {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(video.camera?.isOn == true)
        return video
    }
}
