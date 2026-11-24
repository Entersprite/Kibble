import AppKit
import ChatKit
import DesignSystem

public extension AudioCallWindowHost {
    internal func updateHandGesture(
        call: AudioCallSession, window: NSWindow, video: CallVideoController?,
        people: [CallParticipantDevice]?, actions: inout AudioCallActions
    ) {
        // Only the native camera path supplies frames to Vision.
        guard let video, video.localTrack != nil, let gesture = actions.handGesture else {
            actions.handGesture = nil
            configureHandGesture = nil
            handGesture.stop()
            return
        }
        guard call.phase == .connected, gesture.isEnabled,
              actions.handRaised == false, !actions.isUpdatingHand else {
            configureHandGesture = nil
            handGesture.stop()
            return
        }
        let id = call.id
        let hasPeer = people?.contains { !$0.isLocal && !$0.isPresentation } == true
        configureHandGesture = { [weak self, weak window, weak video] in
            guard let self, let video, let window, self.window === window, callID == id else { return }
            let track = window.isKeyWindow ? video.handGestureTrack : nil
            let scope = video.receivePreferenceScope
            let cameraID = video.camera?.selected
            handGesture.configure(
                call: id, track: track, cameraID: cameraID,
                isSpeaking: hasPeer ? video.localSpeechForGesture : nil
            ) { [weak self, weak window, weak video] in
                guard self?.callID == id, window?.isKeyWindow == true,
                      let video, video.receivePreferenceScope == scope,
                      video.camera?.selected == cameraID, video.handGestureTrack === track
                else { return }
                gesture.raise()
            }
        }
        configureHandGesture?()
        actions.handGestureProgress = handGesture.progress
    }

    func windowDidBecomeKey(_ notification: Notification) {
        configureHandGesture?()
    }

    func windowDidResignKey(_ notification: Notification) {
        preparation.camera.suspendCapture()
        preparation.audio.suspend()
        handGesture.stop()
    }
}
