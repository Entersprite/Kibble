import Foundation
@preconcurrency import LiveKitWebRTC
import LocalBridgeBackend

public extension NativeCallMedia {
    func configureStreamControl(_ channel: CallStreamControlChannel?) throws {
        guard let peer else { throw CallMediaError.closed }
        guard !isExchangingStream, streamChannel == nil else { throw CallMediaError.busy }
        guard let channel else { return }
        guard channel.id < 65535, channel.maxPacketLifeTime == nil || channel.maxRetransmits == nil else {
            throw CallMediaError.negotiationFailed
        }
        let config = LKRTCDataChannelConfiguration()
        config.isOrdered = channel.isOrdered
        config.isNegotiated = true
        config.channelId = Int32(channel.id)
        if let lifetime = channel.maxPacketLifeTime {
            config.maxPacketLifeTime = Int32(lifetime)
        }
        if let retransmits = channel.maxRetransmits {
            config.maxRetransmits = Int32(retransmits)
        }
        guard let created = peer.dataChannel(forLabel: "dcrpc", configuration: config) else {
            throw CallMediaError.negotiationFailed
        }
        streamChannel = created
        created.delegate = self
    }

    /// Opaque, bounded transport only. The bridge supplies request IDs and
    /// validates protobuf responses; no provider identity is parsed by the host.
    func exchangeStreamControl(
        _ request: Data, matches: @escaping @Sendable (Data) -> Bool, timeout: Duration
    ) async throws -> Data {
        guard isConnected, let peer, !request.isEmpty, request.count <= 1_000_000 else {
            throw CallMediaError.connectionFailed
        }
        let current = generation
        try await waitForStreamTurn(current, timeout: timeout)
        isExchangingStream = true
        streamReplies.removeAll()
        streamReplyMatches = matches
        streamTrace = NativeStreamControlTrace(stage: .openingChannel)
        defer {
            if generation == current {
                isExchangingStream = false
                streamReplies.removeAll()
                streamReplyMatches = nil
            }
        }
        try prepareStreamChannel(peer)
        // Channel opening stays bounded independently of the caller's reply
        // budget. Start that budget only after the one request is sent.
        var deadline = ContinuousClock.now.advanced(by: min(timeout, .seconds(8)))
        var sent = false
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard generation == current, isConnected, let channel = streamChannel else {
                throw CallMediaError.closed
            }
            if channel.readyState == .closing || channel.readyState == .closed {
                throw CallMediaError.connectionFailed
            }
            if !sent, channel.readyState == .open {
                guard channel.sendData(LKRTCDataBuffer(data: request, isBinary: true)) else {
                    throw CallMediaError.connectionFailed
                }
                sent = true
                streamTrace.sent = true
                streamTrace.stage = .waitingForReply
                deadline = ContinuousClock.now.advanced(by: timeout)
            }
            while !streamReplies.isEmpty {
                let response = streamReplies.removeFirst()
                if matches(response) {
                    return response
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CallMediaError.signalingTimedOut
    }

    func streamControlDiagnosticReport() -> [String] {
        let state = switch streamChannel?.readyState {
        case .connecting: "connecting"
        case .open: "open"
        case .closing: "closing"
        case .closed: "closed"
        case nil: "absent"
        @unknown default: "unknown"
        }
        return [streamTrace.line(channel: state)]
    }

    private func waitForStreamTurn(_ current: UUID, timeout: Duration) async throws {
        let queueDeadline = ContinuousClock.now.advanced(by: timeout)
        while isExchangingStream {
            try Task.checkCancellation()
            guard generation == current else { throw CallMediaError.closed }
            guard ContinuousClock.now < queueDeadline else { throw CallMediaError.signalingTimedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard generation == current else { throw CallMediaError.closed }
    }

    private func prepareStreamChannel(_ peer: LKRTCPeerConnection) throws {
        guard streamChannel == nil else { return }
        let config = LKRTCDataChannelConfiguration()
        config.isOrdered = true
        config.isNegotiated = false
        guard let channel = peer.dataChannel(forLabel: "dcrpc", configuration: config) else {
            throw CallMediaError.connectionFailed
        }
        streamChannel = channel
        channel.delegate = self
    }
}
