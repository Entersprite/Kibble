import Foundation
@preconcurrency import LiveKitWebRTC
import LocalBridgeBackend
import Testing
@testable import MacHost

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct NativeNegotiatedStreamTests {
    @Test(arguments: [UInt16(0), 42])
    func assignedStreamReceivesReplies(_ id: UInt16) async throws {
        try await exchange(assigned: true, configuration: .init(id: id, isOrdered: true))
    }

    @Test func assignedStreamReceivesADelayedReply() async throws {
        try await exchange(
            assigned: true, configuration: .init(id: 0, isOrdered: true), replyDelay: .milliseconds(1200)
        )
    }

    @Test(arguments: [
        CallStreamControlChannel(id: 42, isOrdered: true, maxPacketLifeTime: 0),
        CallStreamControlChannel(id: 42, isOrdered: true, maxPacketLifeTime: 1000),
        CallStreamControlChannel(id: 42, isOrdered: true, maxRetransmits: 0),
        CallStreamControlChannel(id: 42, isOrdered: true, maxRetransmits: 3)
    ])
    func serverReliabilityLimitsSurviveNativeRequestReply(
        _ configuration: CallStreamControlChannel
    ) async throws {
        try await exchange(assigned: true, configuration: configuration)
    }

    @Test func unrelatedInBandChannelCannotReceiveAssignedStreamReplies() async throws {
        try await exchange(assigned: false, configuration: .init(id: 42, isOrdered: true))
    }

    @Test(arguments: [
        ("meet_messages", CallDataChannelCompression.none), ("captions_v2", .none), ("captions_v2", .gzip)
    ])
    func assignedActivityStreamRoundTripsAmidUnrelatedFrames(
        _ label: String, _ compression: CallDataChannelCompression
    ) async throws {
        let client = NativeCallMedia(presentation: true), server = NativeCallMedia(presentation: true)
        defer { client.close(); server.close() }
        _ = try await client.makeAudioOffer(serverControlChannel: "collections")
        client.expectedControlChannel = nil
        let (remote, _) = try server.preparePeer(serverControlChannel: nil)
        let assignment = CallStreamControlChannel(id: 42, isOrdered: true, compression: compression)
        let other = label == "meet_messages" ? "captions_v2" : "meet_messages"
        try client.configureActivityChannel(assignment, label: label)
        try server.configureActivityChannel(assignment, label: label)
        let otherAssignment = CallStreamControlChannel(id: 43, isOrdered: true)
        try client.configureActivityChannel(otherAssignment, label: other)
        try server.configureActivityChannel(otherAssignment, label: other)
        let local = try #require(client.peer)
        try await connect(local, remote)
        try await client.waitUntilConnected(timeout: .seconds(5))

        let request = Data([42]), reply = Data([255]), shiftedReply = Data([254])
        server.activityReplyChannel = label
        server.activityReplyMatches = { $0 == request }
        let exchange = Task {
            try await client.exchangeActivityData(channel: label, data: request) {
                $0 == reply || $0 == shiftedReply
            }
        }
        for _ in 0 ..< 200 where server.activityReply == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(server.activityReply == request)
        let channel = try #require(server.activityChannels[label]?.channel)
        try await sendWrongChannelFrame(shiftedReply, on: other, from: server, to: client)
        #expect(client.activityReply == nil)
        for index in 1 ... 32 {
            #expect(channel.sendData(LKRTCDataBuffer(data: Data([UInt8(index)]), isBinary: true)))
        }
        if compression == .gzip {
            #expect(channel.sendData(LKRTCDataBuffer(data: shiftedReply, isBinary: true)))
        }
        try await server.sendActivityData(channel: label, data: reply)
        #expect(try await exchange.value == reply)
        #expect(client.activityChannels[label]?.channel.channelId == 42)
        #expect(client.activityChannels[label]?.channel.isNegotiated == true)
        await #expect(throws: CallMediaError.connectionFailed) {
            try await client.prepareActivityChannel("reactions")
        }
        client.close()
        #expect(client.activityChannels.isEmpty && client.activityReplyMatches == nil)
    }

    private func sendWrongChannelFrame(
        _ data: Data, on label: String, from server: NativeCallMedia, to client: NativeCallMedia
    ) async throws {
        let channel = try #require(server.activityChannels[label]?.channel)
        try await server.prepareActivityChannel(label)
        let receipt = FrameReceipt()
        client.setEventHandler { event in
            if case let .activityData(channel, received) = event, channel == label, received == data {
                await receipt.markReceived()
            }
        }
        #expect(channel.sendData(LKRTCDataBuffer(data: data, isBinary: true)))
        for _ in 0 ..< 200 where !receipt.received {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(receipt.received)
    }

    private func exchange(
        assigned: Bool, configuration: CallStreamControlChannel, replyDelay: Duration? = nil
    ) async throws {
        let client = NativeCallMedia(presentation: true), server = NativeCallMedia(presentation: true)
        defer { client.close(); server.close() }
        _ = try await client.makeAudioOffer(serverControlChannel: "collections")
        // This local server exercises only the stream-control lane, without a
        // provider collections service, microphone or Google network request.
        client.expectedControlChannel = nil
        let (remote, _) = try server.preparePeer(serverControlChannel: nil)
        remote.delegate = nil
        try server.configureStreamControl(configuration)
        try client.configureStreamControl(assigned ? configuration : nil)
        let local = try #require(client.peer)
        try await connect(local, remote)
        try await client.waitUntilConnected(timeout: .seconds(5))
        let request = Data([8, 7, 34, 0]), reply = Data([8, 7, 42, 0])
        server.isExchangingStream = true
        server.streamReplyMatches = { $0 == request }
        // Match the usual native stream budget for a valid exchange. Only the
        // wrong-channel case deliberately waits for a short deadline to expire.
        let timeout: Duration = assigned ? .seconds(8) : .seconds(1)
        let exchange = Task {
            try await client.exchangeStreamControl(request, matches: { $0 == reply }, timeout: timeout)
        }
        defer { exchange.cancel() }
        if assigned {
            let deadline = ContinuousClock.now + timeout
            while server.streamReplies.isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(server.streamReplies == [request])
            let channel = try #require(server.streamChannel)
            if let replyDelay {
                try await Task.sleep(for: replyDelay)
            }
            #expect(channel.sendData(LKRTCDataBuffer(data: reply, isBinary: true)))
            #expect(try await exchange.value == reply)
            #expect(client.streamChannel?.isNegotiated == true)
            #expect(client.streamChannel?.channelId == Int32(configuration.id))
            if let lifetime = configuration.maxPacketLifeTime {
                #expect(client.streamChannel?.maxPacketLifeTime == lifetime)
            }
            if let retransmits = configuration.maxRetransmits {
                #expect(client.streamChannel?.maxRetransmits == retransmits)
            }
        } else {
            await #expect(throws: CallMediaError.signalingTimedOut) { try await exchange.value }
            #expect(server.streamReplies.isEmpty)
            let report = client.streamControlDiagnosticReport().joined(separator: "\n")
            #expect(report.contains("channel=open; sent=true; received=0"))
        }
    }

    @Test func conflictingTransportOptionsCannotCreateAChannel() throws {
        let media = NativeCallMedia(presentation: true)
        _ = try media.preparePeer(serverControlChannel: nil)
        defer { media.close() }
        #expect(throws: CallMediaError.negotiationFailed) {
            try media.configureStreamControl(.init(
                id: 42, isOrdered: true, maxPacketLifeTime: 0, maxRetransmits: 0
            ))
        }
        #expect(media.streamChannel == nil)
    }

    private func connect(_ local: LKRTCPeerConnection, _ remote: LKRTCPeerConnection) async throws {
        try await gathered(local)
        let offer = try #require(local.localDescription)
        try await set(offer, local: false, peer: remote)
        let answer = try await answer(remote)
        try await set(answer, local: true, peer: remote)
        try await gathered(remote)
        let gatheredAnswer = try #require(remote.localDescription)
        try await set(gatheredAnswer, local: false, peer: local)
    }

    private func answer(_ peer: LKRTCPeerConnection) async throws -> LKRTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            peer.answer(for: constraints) { value, error in
                if let value {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(throwing: error ?? CallMediaError.negotiationFailed)
                }
            }
        }
    }

    private func set(
        _ description: LKRTCSessionDescription,
        local: Bool,
        peer: LKRTCPeerConnection
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let completion: @Sendable (Error?) -> Void = { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            if local {
                peer.setLocalDescription(description, completionHandler: completion)
            } else {
                peer.setRemoteDescription(description, completionHandler: completion)
            }
        }
    }

    private func gathered(_ peer: LKRTCPeerConnection) async throws {
        for _ in 0 ..< 300 where peer.iceGatheringState != .complete {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(peer.iceGatheringState == .complete)
    }
}

@MainActor
private final class FrameReceipt {
    private(set) var received = false

    func markReceived() {
        received = true
    }
}
