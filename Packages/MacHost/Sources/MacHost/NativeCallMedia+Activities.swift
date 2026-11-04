import Foundation
@preconcurrency import LiveKitWebRTC
import LocalBridgeBackend

public extension NativeCallMedia {
    func prepareActivityChannel(_ label: String) async throws {
        guard ["reactions", "meet_messages"].contains(label),
              isConnected, let peer else { throw CallMediaError.connectionFailed }
        let current = generation
        let channel: LKRTCDataChannel
        if let existing = activityChannels[label] {
            channel = existing
        } else {
            let config = LKRTCDataChannelConfiguration()
            config.isOrdered = true; config.isNegotiated = false
            guard let created = peer.dataChannel(forLabel: label, configuration: config) else {
                throw CallMediaError.connectionFailed
            }
            channel = created; activityChannels[label] = channel; channel.delegate = self
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while channel.readyState == .connecting {
            try Task.checkCancellation()
            guard generation == current,
                  ContinuousClock.now < deadline else { throw CallMediaError.signalingTimedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard generation == current, isConnected,
              channel.readyState == .open else { throw CallMediaError.connectionFailed }
    }

    func sendActivityData(channel label: String, data: Data) async throws {
        guard !data.isEmpty, data.count <= 64000 else { throw CallMediaError.connectionFailed }
        try await prepareActivityChannel(label)
        guard isConnected, let channel = activityChannels[label], channel.readyState == .open,
              channel.sendData(LKRTCDataBuffer(data: data, isBinary: true))
        else { throw CallMediaError.connectionFailed }
    }

    func exchangeActivityData(
        channel: String,
        data: Data,
        matches: @escaping @Sendable (Data) -> Bool
    ) async throws -> Data {
        guard !exchangingActivity else { throw CallMediaError.busy }
        let current = generation
        exchangingActivity = true; activityReplies = []
        defer {
            if generation == current {
                exchangingActivity = false; activityReplies = []
            }
        }
        try await sendActivityData(channel: channel, data: data)
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard generation == current, isConnected else { throw CallMediaError.closed }
            while !activityReplies.isEmpty {
                let value = activityReplies.removeFirst()
                if matches(value) {
                    return value
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CallMediaError.signalingTimedOut
    }
}
