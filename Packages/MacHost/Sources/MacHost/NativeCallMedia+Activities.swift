import Foundation
@preconcurrency import LiveKitWebRTC
import LocalBridgeBackend

public extension NativeCallMedia {
    var supportsActivityChannelAssignments: Bool {
        true
    }

    var supportsGzipActivityChannels: Bool {
        true
    }

    func configureActivityChannel(_ channel: CallStreamControlChannel, label: String) throws {
        guard Self.activityLabels.contains(label), activityChannels[label] == nil else {
            throw CallMediaError.negotiationFailed
        }
        let assigned = try createAssignedChannel(channel, label: label)
        activityChannels[label] = NativeActivityChannel(channel: assigned, compression: channel.compression)
    }

    func prepareActivityChannel(_ label: String) async throws {
        guard isConnected,
              let channel = activityChannels[label]?.channel else { throw CallMediaError.connectionFailed }
        let current = generation
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
        let current = generation
        try await prepareActivityChannel(label)
        try Task.checkCancellation()
        guard generation == current, isConnected,
              let assigned = activityChannels[label], assigned.channel.readyState == .open
        else { throw CallMediaError.connectionFailed }
        let frame = assigned.compression == .gzip ? try NativeActivityGzip.encode(data) : data
        guard assigned.channel.sendData(LKRTCDataBuffer(data: frame, isBinary: true))
        else { throw CallMediaError.connectionFailed }
    }

    func exchangeActivityData(
        channel: String,
        data: Data,
        matches: @escaping @Sendable (Data) -> Bool
    ) async throws -> Data {
        guard activityReplyMatches == nil else { throw CallMediaError.busy }
        let current = generation
        activityReplyChannel = channel; activityReplyMatches = matches; activityReply = nil
        defer {
            if generation == current {
                activityReplyChannel = nil; activityReplyMatches = nil; activityReply = nil
            }
        }
        try await sendActivityData(channel: channel, data: data)
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard generation == current, isConnected, activityChannels[channel]?.channel.readyState == .open
            else { throw CallMediaError.closed }
            if let activityReply {
                return activityReply
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CallMediaError.signalingTimedOut
    }
}

struct NativeActivityChannel {
    let channel: LKRTCDataChannel
    let compression: CallDataChannelCompression
}

extension NativeCallMedia {
    static let activityLabels: Set = ["reactions", "meet_messages", "captions_v2"]
}
