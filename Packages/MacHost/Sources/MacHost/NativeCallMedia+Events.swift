import Foundation
@preconcurrency import LiveKitWebRTC
import LocalBridgeBackend

extension NativeCallMedia: LKRTCPeerConnectionDelegate {
    public nonisolated func peerConnection(
        _ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState
    ) {
        received(newState, from: peerConnection)
    }

    public nonisolated func peerConnection(
        _: LKRTCPeerConnection, didChange _: LKRTCSignalingState
    ) {}

    public nonisolated func peerConnection(_: LKRTCPeerConnection, didAdd _: LKRTCMediaStream) {}
    public nonisolated func peerConnection(_: LKRTCPeerConnection, didRemove _: LKRTCMediaStream) {}
    public nonisolated func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {}

    public nonisolated func peerConnection(
        _: LKRTCPeerConnection, didChange _: LKRTCIceConnectionState
    ) {}

    public nonisolated func peerConnection(
        _: LKRTCPeerConnection, didChange _: LKRTCIceGatheringState
    ) {}

    public nonisolated func peerConnection(_: LKRTCPeerConnection, didGenerate _: LKRTCIceCandidate) {}
    public nonisolated func peerConnection(_: LKRTCPeerConnection, didRemove _: [LKRTCIceCandidate]) {}
    public nonisolated func peerConnection(
        _ peerConnection: LKRTCPeerConnection,
        didOpen channel: LKRTCDataChannel
    ) {
        let identity = ObjectIdentifier(peerConnection)
        Task { @MainActor [weak self] in
            guard let self, let peer, ObjectIdentifier(peer) == identity else {
                channel.close()
                return
            }
            if Self.activityLabels.contains(channel.label) {
                if activityChannels[channel.label]?.channel !== channel {
                    channel.close()
                }
                return
            }
            if channel.label == "dcrpc" {
                if streamChannel == nil {
                    streamChannel = channel
                    channel.delegate = self
                } else if streamChannel !== channel {
                    channel.close()
                }
                return
            }
            guard let expectedControlChannel, channel.label == expectedControlChannel else {
                channel.close()
                return
            }
            if let controlChannel {
                if ObjectIdentifier(controlChannel) != ObjectIdentifier(channel) {
                    channel.close()
                }
                return
            }
            controlChannel = channel
            channel.delegate = self
        }
    }
}

extension NativeCallMedia: LKRTCDataChannelDelegate {
    public nonisolated func dataChannelDidChangeState(_ channel: LKRTCDataChannel) {
        let identity = ObjectIdentifier(channel)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let activity = activityChannels
                .first(where: { ObjectIdentifier($0.value.channel) == identity }) {
                if channel.readyState == .closed || channel.readyState == .closing {
                    activityChannels[activity.key] = nil
                    await eventHandler?(.activityClosed(channel: activity.key))
                }
                return
            }
            guard let controlChannel, ObjectIdentifier(controlChannel) == identity else { return }
            if controlChannel.readyState == .closed || controlChannel.readyState == .closing {
                await eventHandler?(.failed)
            }
        }
    }

    public nonisolated func dataChannel(
        _ channel: LKRTCDataChannel,
        didReceiveMessageWith buffer: LKRTCDataBuffer
    ) {
        guard buffer.isBinary, !buffer.data.isEmpty, buffer.data.count <= 1_000_000 else { return }
        let data = buffer.data
        let identity = ObjectIdentifier(channel)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let activity = activityChannels
                .first(where: { ObjectIdentifier($0.value.channel) == identity }) {
                let frame = activity.value.compression == .gzip ? try? NativeActivityGzip.decode(data) : data
                guard let frame else { return }
                if activityReply == nil, activity.key == activityReplyChannel,
                   activityReplyMatches?(frame) == true {
                    activityReply = frame
                }
                await eventHandler?(.activityData(channel: activity.key, data: frame))
                return
            }
            if let streamChannel, ObjectIdentifier(streamChannel) == identity {
                if isExchangingStream, let streamReplyMatches {
                    let matched = streamReplyMatches(data)
                    streamTrace.receive(matched: matched)
                    if matched, streamReplies.isEmpty {
                        streamReplies.append(data)
                    }
                }
                return
            }
            guard let controlChannel, ObjectIdentifier(controlChannel) == identity else { return }
            // Coalesce invalidations in the bridge and fetch versioned full
            // snapshots. No server payload is retained or logged by the host.
            await eventHandler?(.collectionsChanged)
        }
    }
}
