import Foundation
@preconcurrency import LiveKitWebRTC
import LocalBridgeBackend

public extension NativeCallMedia {
    var supportsScreenSharing: Bool {
        videoController != nil && !isPresentation
    }

    func configureScreenSharing(
        start: (@Sendable (any CallMediaEngine) async throws -> Void)?,
        stop: (@Sendable () async -> Bool)?
    ) {
        guard let videoController else { return }
        if let screenScope {
            videoController.screenSharing.clear(ifCurrent: screenScope)
        }
        screenScope = nil
        screenRoute = nil
        if let start, let stop {
            let route = NativeCallScreenSharing(start: start, stop: stop)
            screenRoute = route
            screenScope = videoController.screenSharing.install(route)
        }
    }

    func showRemoteVideos(_ slots: [CallRemoteVideoSlot]) {
        guard let videoScope, let video else { return }
        let tracks: [CallRemoteVideoTrack] = slots.compactMap { slot in
            guard video.receivers.indices.contains(slot.index),
                  let track = video.receivers[slot.index].receiver.track as? LKRTCVideoTrack
            else { return nil }
            return CallRemoteVideoTrack(
                index: slot.index, track: track, isPresentation: slot.isPresentation,
                isVisible: slot.isVisible,
                participantID: slot.participantID, displayName: slot.displayName
            )
        }
        videoController?.showRemotes(tracks, ifCurrent: videoScope)
    }

    func showRemotePresentation(_ visible: Bool) {
        guard let videoScope else { return }
        videoController?.showPresentation(visible, ifCurrent: videoScope)
    }

    var supportsVideo: Bool {
        videoController != nil || isPresentation
    }

    internal func prepareVideo(factory: LKRTCPeerConnectionFactory, peer: LKRTCPeerConnection) throws {
        guard supportsVideo else { return }
        video = try NativeCallVideo(factory: factory, peer: peer, presentation: isPresentation)
    }

    func configureCamera(announce: (@Sendable (Bool) async throws -> Void)?) {
        video?.announcement = announce
        if announce != nil, let video, let videoController {
            videoScope = videoController.install(video, local: video.track)
            if let videoScope {
                videoController.showRemote(
                    video.receiver.receiver.track as? LKRTCVideoTrack,
                    visible: false,
                    ifCurrent: videoScope
                )
            }
        } else if let videoScope {
            videoController?.clear(ifCurrent: videoScope)
            self.videoScope = nil
        }
    }

    func reportVideoUnavailable() {
        guard let video, let videoController else { return }
        videoScope = videoController.unavailable(video, local: video.track)
    }

    func showRemoteVideo(_ visible: Bool) {
        guard let videoScope, let video else { return }
        videoController?.showRemote(
            video.receiver.receiver.track as? LKRTCVideoTrack,
            visible: visible,
            ifCurrent: videoScope
        )
    }

    func applyVideoAnswer(_ sdp: String) async throws {
        guard let peer, video != nil, !isNegotiating else { throw CallMediaError.busy }
        let scope = generation
        isNegotiating = true
        defer {
            if generation == scope {
                isNegotiating = false
            }
        }
        try await setDescription(sdp, local: false, connection: peer)
        try check(scope)
    }

    func cancelVideoOffer() async {
        guard let peer, peer.signalingState == .haveLocalOffer else { return }
        await withCheckedContinuation { continuation in
            peer.setLocalDescription(LKRTCSessionDescription(type: .rollback, sdp: "")) { _ in
                continuation.resume()
            }
        }
    }

    func renewVideoOffer() async throws -> CallAudioOffer {
        guard let peer, video != nil, !isNegotiating else { throw CallMediaError.busy }
        isNegotiating = true
        let scope = generation
        defer {
            if generation == scope {
                isNegotiating = false
            }
        }
        let description: LKRTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: LKRTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: nil
            )) { description, error in
                if error != nil {
                    continuation.resume(throwing: CallMediaError.negotiationFailed)
                } else if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: CallMediaError.negotiationFailed)
                }
            }
        }
        try check(scope)
        try await setDescription(description.sdp, local: true, connection: peer)
        try check(scope)
        return CallAudioOffer(sdp: description.sdp, srtpProfile: .aeadAES256GCM)
    }
}
