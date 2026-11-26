import AVFoundation
import Foundation
@preconcurrency import LiveKitWebRTC
import Testing
@testable import MacHost

@MainActor
struct NativeCallAudioReceptionTests {
    @Test(arguments: [true, false])
    func unsignaledAudioSurvivesVideoRenegotiation(singleReceiver: Bool) async throws {
        LKRTCSetMinDebugLogLevel(.none)
        #expect(LKRTCInitializeSSL())
        let receivingDevice = NativePresentationAudioDevice()
        let sendingDevice = NativePresentationAudioDevice()
        let receivingFactory = factory(receivingDevice)
        let sendingFactory = factory(sendingDevice)
        let receiver = try peer(receivingFactory)
        let sender = try peer(sendingFactory)
        defer { receiver.close(); sender.close() }
        let audio = receivingFactory.audioTrack(
            with: receivingFactory.audioSource(with: constraints),
            trackId: "local"
        )
        _ = receiver.add(audio, streamIds: ["local"])
        try NativeCallMedia.configureAudioCodecs(receiver, factory: receivingFactory)
        let video = try NativeCallVideo(
            factory: receivingFactory,
            peer: receiver,
            presentation: singleReceiver
        )
        #expect(video.receivers.count == (singleReceiver ? 1 : 8))
        defer { video.close() }
        _ = sender.add(
            sendingFactory.audioTrack(with: sendingFactory.audioSource(with: constraints), trackId: "remote"),
            streamIds: ["remote"]
        )
        let answer = try await connect(receiver: receiver, sender: sender)
        sendingDevice.enable()
        let sample = try sample()
        var previous = 0
        for activeVideos in [0, 1, singleReceiver ? 1 : 2, 0] {
            let generated = try await description(receiver, offer: true)
            #expect(generated.sdp.contains("a=mid:kibble-audio\r\n"))
            #expect(try NativeCallSDP.audioMIDLast(generated.sdp) == generated.sdp)
            try await set(generated, local: true, peer: receiver)
            try await set(
                LKRTCSessionDescription(type: .answer, sdp: bindingVideos(answer, count: activeVideos)),
                local: false,
                peer: receiver
            )
            previous = try await sendAudio(
                sample,
                device: sendingDevice,
                sender: sender,
                receiver: receiver,
                previous: previous
            )
        }
    }

    private func sendAudio(
        _ sample: CMSampleBuffer,
        device: NativePresentationAudioDevice,
        sender: LKRTCPeerConnection,
        receiver: LKRTCPeerConnection,
        previous: Int
    ) async throws -> Int {
        for _ in 0 ..< 100 {
            device.receive(sample)
            try await Task.sleep(for: .milliseconds(10))
        }
        let inbound = await packets(receiver, type: "inbound-rtp")
        let outbound = await packets(sender, type: "outbound-rtp")
        #expect(outbound > 10)
        #expect(
            inbound > previous + 10,
            "Audio received \(inbound), previously \(previous), sent \(outbound)"
        )
        return inbound
    }

    private func connect(receiver: LKRTCPeerConnection, sender: LKRTCPeerConnection) async throws -> String {
        _ = try #require(receiver.dataChannel(
            forLabel: "ignored", configuration: LKRTCDataChannelConfiguration()
        ))
        let generated = try await description(receiver, offer: true)
        let offer = try LKRTCSessionDescription(type: .offer, sdp: NativeCallSDP.audioMIDLast(generated.sdp))
        try await set(offer, local: true, peer: receiver)
        try await gathered(receiver)
        let gatheredOffer = try #require(receiver.localDescription)
        // The server does not negotiate MID or signal its audio SSRC. The video
        // receive sections stay open before their explicit sources are known.
        let remoteOffer = LKRTCSessionDescription(type: .offer, sdp: withoutMIDExtension(gatheredOffer.sdp))
        try await set(remoteOffer, local: false, peer: sender)
        let answer = try await description(sender, offer: false)
        let serverAnswer = LKRTCSessionDescription(type: .answer, sdp: openVideoReceivers(answer.sdp))
        try await set(serverAnswer, local: true, peer: sender)
        try await gathered(sender)
        let gatheredAnswer = try #require(sender.localDescription)
        try await set(
            LKRTCSessionDescription(type: .answer, sdp: withoutAudioSource(gatheredAnswer.sdp)),
            local: false,
            peer: receiver
        )
        for _ in 0 ..< 300 {
            if receiver.connectionState == .connected, sender.connectionState == .connected {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(receiver.connectionState == .connected)
        try #require(sender.connectionState == .connected)
        return withoutAudioSource(gatheredAnswer.sdp)
    }

    private func bindingVideos(_ sdp: String, count: Int) -> String {
        var index = -1
        return sdp.components(separatedBy: .newlines).filter { !$0.isEmpty }.flatMap { line -> [String] in
            if line.hasPrefix("m=video ") {
                index += 1
            }
            // The first video section receives our camera. Remote tracks bind
            // to the following receive slots, as camera/screen sources arrive.
            if line == "a=sendonly", count > 0, (1 ... count).contains(index) {
                let source = 5000 + index
                return [
                    line,
                    "a=msid:remote-video-\(index) video-\(index)",
                    "a=ssrc:\(source) cname:remote-video-\(index)",
                    "a=ssrc:\(source) msid:remote-video-\(index) video-\(index)"
                ]
            }
            return [line]
        }.joined(separator: "\r\n") + "\r\n"
    }

    private var constraints: LKRTCMediaConstraints {
        LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    }

    private func factory(_ device: NativePresentationAudioDevice) -> LKRTCPeerConnectionFactory {
        LKRTCPeerConnectionFactory(
            encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory(),
            audioDevice: device
        )
    }

    private func peer(_ factory: LKRTCPeerConnectionFactory) throws -> LKRTCPeerConnection {
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        return try #require(factory.peerConnection(with: config, constraints: constraints, delegate: nil))
    }

    private func description(
        _ peer: LKRTCPeerConnection,
        offer: Bool
    ) async throws -> LKRTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            let completion: @Sendable (LKRTCSessionDescription?, Error?) -> Void = { value, error in
                if let value {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(throwing: error ?? ReceptionFailure.description)
                }
            }
            if offer {
                peer.offer(for: constraints, completionHandler: completion)
            } else {
                peer.answer(for: constraints, completionHandler: completion)
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
        for _ in 0 ..< 300 {
            if peer.iceGatheringState == .complete {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(peer.iceGatheringState == .complete)
    }

    private func withoutMIDExtension(_ sdp: String) -> String {
        sdp.components(separatedBy: .newlines)
            .filter { !$0.isEmpty && !$0.contains("urn:ietf:params:rtp-hdrext:sdes:mid") }
            .joined(separator: "\r\n") + "\r\n"
    }

    private func openVideoReceivers(_ sdp: String) -> String {
        var video = false
        return sdp.components(separatedBy: .newlines).filter { !$0.isEmpty }.map { line in
            if line.hasPrefix("m=") {
                video = line.hasPrefix("m=video")
            }
            return video && line == "a=inactive" ? "a=sendonly" : line
        }.joined(separator: "\r\n") + "\r\n"
    }

    private func withoutAudioSource(_ sdp: String) -> String {
        var audio = false
        return sdp.components(separatedBy: .newlines).filter { line in
            if line.hasPrefix("m=") {
                audio = line.hasPrefix("m=audio")
            }
            return !line.isEmpty && !(audio && (line.hasPrefix("a=ssrc:") || line.hasPrefix("a=msid:")))
        }.joined(separator: "\r\n") + "\r\n"
    }

    private func packets(_ peer: LKRTCPeerConnection, type: String) async -> Int {
        await withCheckedContinuation { continuation in
            peer.statistics { report in
                let total = report.statistics.values
                    .filter { $0.type == type && ($0.values["kind"] as? String) == "audio" }.reduce(0) {
                        $0 +
                            (($1
                                    .values[type == "inbound-rtp" ? "packetsReceived" :
                                        "packetsSent"] as? NSNumber)?
                                .intValue ?? 0)
                    }
                continuation.resume(returning: total)
            }
        }
    }

    private func sample() throws -> CMSampleBuffer {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        let channels = try #require(buffer.floatChannelData)
        for index in 0 ..< 480 {
            let value = Float(sin(Double(index) * 2 * .pi * 440 / 48000)) * 0.25
            channels[0][index] = value; channels[1][index] = value
        }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        try #require(CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format.formatDescription,
            sampleCount: 480,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample
        ) == noErr)
        let result = try #require(sample)
        try #require(CMSampleBufferSetDataBufferFromAudioBufferList(
            result,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList
        ) == noErr)
        return result
    }
}

private enum ReceptionFailure: Error { case description }
