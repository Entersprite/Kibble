import Foundation
@preconcurrency import LiveKitWebRTC
import LocalBridgeBackend

public extension NativeCallMedia {
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
        defer {
            if generation == current {
                isExchangingStream = false
                streamReplies.removeAll()
            }
        }
        try prepareStreamChannel(peer)
        let deadline = ContinuousClock.now.advanced(by: timeout)
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
