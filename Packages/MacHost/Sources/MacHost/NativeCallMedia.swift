import AVFoundation
import Foundation
import LocalBridgeBackend
@preconcurrency import WebRTC

/// Kibble's own libWebRTC peer. Does not load Meet, reuse a browser, or send an
/// invitation. Hardware starts only after explicit audio offer preparation.
@MainActor
public final class NativeCallMedia: NSObject, CallMediaEngine {
    private static let sslReady: Bool = {
        RTCSetMinDebugLogLevel(.none)
        return RTCInitializeSSL()
    }()

    private var peer: RTCPeerConnection?
    private var audio: RTCAudioTrack?
    private var bootstrapChannel: RTCDataChannel?
    private var controlChannel: RTCDataChannel?
    private var expectedControlChannel: String?
    private var generation = UUID()
    private var isNegotiating = false
    private var connectionState: RTCPeerConnectionState = .new
    private var muted = false
    private let microphoneAccess: @MainActor @Sendable () async -> Bool

    public init(
        microphoneAccess: @escaping @MainActor @Sendable () async -> Bool = {
            await AVCaptureDevice.requestAccess(for: .audio)
        }
    ) {
        self.microphoneAccess = microphoneAccess
        super.init()
    }

    public var isConnected: Bool {
        peer != nil && connectionState == .connected
            && (expectedControlChannel == nil || controlChannel?.readyState == .open)
    }

    public func makeAudioOffer(serverControlChannel: String?) async throws -> CallAudioOffer {
        guard peer == nil, !isNegotiating else { throw CallMediaError.busy }
        isNegotiating = true
        let current = generation
        defer {
            if generation == current {
                isNegotiating = false
            }
        }
        do {
            let permitted = await microphoneAccess()
            try check(current)
            guard permitted else { throw CallMediaError.microphoneDenied }
            guard Self.sslReady else { throw CallMediaError.negotiationFailed }
            let (connection, constraints) = try preparePeer(serverControlChannel: serverControlChannel)
            let offer: String = try await withCheckedThrowingContinuation { continuation in
                connection.offer(for: constraints) { description, error in
                    guard error == nil, let description else {
                        continuation.resume(throwing: CallMediaError.negotiationFailed)
                        return
                    }
                    continuation.resume(returning: description.sdp)
                }
            }
            try check(current)
            try await setDescription(offer, local: true, connection: connection)
            try check(current)
            return CallAudioOffer(sdp: offer, srtpProfile: .aeadAES256GCM)
        } catch {
            if generation == current {
                close()
            }
            throw error
        }
    }

    public func applyAnswer(_ sdp: String) async throws {
        guard let peer else { throw CallMediaError.closed }
        guard !isNegotiating else { throw CallMediaError.busy }
        isNegotiating = true
        let current = generation
        defer {
            if generation == current {
                isNegotiating = false
            }
        }
        do {
            try await setDescription(sdp, local: false, connection: peer)
            try check(current)
        } catch {
            if generation == current {
                close()
            }
            throw error
        }
    }

    public func waitUntilConnected(timeout: Duration) async throws {
        guard peer != nil else { throw CallMediaError.closed }
        let current = generation
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try check(current)
            switch connectionState {
            case .connected:
                if isConnected {
                    return
                }
            case .failed, .closed: throw CallMediaError.connectionFailed
            default: break
            }
            if let controlChannel,
               controlChannel.readyState == .closing || controlChannel.readyState == .closed {
                throw CallMediaError.connectionFailed
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CallMediaError.timedOut
    }

    public func setMuted(_ muted: Bool) {
        self.muted = muted
        audio?.isEnabled = !muted
    }

    public func close() {
        generation = UUID()
        isNegotiating = false
        audio?.isEnabled = false
        audio = nil
        controlChannel?.delegate = nil
        controlChannel?.close()
        controlChannel = nil
        bootstrapChannel?.close()
        bootstrapChannel = nil
        expectedControlChannel = nil
        peer?.close()
        peer = nil
        connectionState = .closed
    }

    private func check(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw CallMediaError.closed }
    }

    private static func audioCryptoOptions() -> RTCCryptoOptions {
        RTCCryptoOptions(
            srtpEnableGcmCryptoSuites: true, srtpPreferGcmCryptoSuites: true,
            srtpEnableAes128Sha1_32CryptoCipher: false, srtpEnableAes128Sha1_80CryptoCipher: true,
            srtpEnableEncryptedRtpHeaderExtensions: false, sframeRequireFrameEncryption: false
        )
    }

    private func preparePeer(
        serverControlChannel: String?
    ) throws -> (RTCPeerConnection, RTCMediaConstraints) {
        let factory = RTCPeerConnectionFactory()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.cryptoOptions = Self.audioCryptoOptions()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(
            with: configuration, constraints: constraints, delegate: self
        ) else { throw CallMediaError.negotiationFailed }
        peer = connection
        expectedControlChannel = serverControlChannel
        let track = factory.audioTrack(withTrackId: UUID().uuidString)
        track.isEnabled = !muted
        audio = track
        guard connection.add(track, streamIds: [UUID().uuidString]) != nil else {
            throw CallMediaError.negotiationFailed
        }
        try Self.configureAudioCodecs(connection, factory: factory)
        if serverControlChannel != nil {
            // The browser also creates an ignored channel before its
            // initial offer, enabling the bundled SCTP m-line. The real
            // push channel arrives later from the server via DCEP.
            let channelConfig = RTCDataChannelConfiguration()
            channelConfig.isOrdered = true
            channelConfig.isNegotiated = false
            guard let channel = connection.dataChannel(forLabel: "ignored", configuration: channelConfig)
            else {
                throw CallMediaError.negotiationFailed
            }
            bootstrapChannel = channel
        }
        return (connection, constraints)
    }

    private static func configureAudioCodecs(
        _ connection: RTCPeerConnection, factory: RTCPeerConnectionFactory
    ) throws {
        // Meet's browser uses setCodecPreferences with audio/opus and audio/red.
        // Apply that limit to the actual peer before generating or installing
        // its offer; do not advertise the SDK's legacy telephony codecs.
        let codecs = factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindAudio).codecs
            .filter { codec in
                ["audio/opus", "audio/red"].contains(codec.mimeType.lowercased())
                    && codec.clockRate?.intValue == 48000 && codec.numChannels?.intValue == 2
            }
        guard codecs.contains(where: { $0.mimeType.lowercased() == "audio/opus" }),
              connection.transceivers.count == 1,
              let transceiver = connection.transceivers.first else {
            throw CallMediaError.negotiationFailed
        }
        do {
            // The empty error argument selects the throwing API; the one-
            // argument overload is deprecated and discards native failures.
            try transceiver.setCodecPreferences(codecs, error: ())
        } catch {
            throw CallMediaError.negotiationFailed
        }
    }

    private func setDescription(_ sdp: String, local: Bool, connection: RTCPeerConnection) async throws {
        let description = RTCSessionDescription(type: local ? .offer : .answer, sdp: sdp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let completion: @Sendable (Error?) -> Void = { error in
                if error != nil {
                    continuation.resume(throwing: CallMediaError.negotiationFailed)
                } else {
                    continuation.resume()
                }
            }
            if local {
                connection.setLocalDescription(description, completionHandler: completion)
            } else {
                connection.setRemoteDescription(description, completionHandler: completion)
            }
        }
        if local {
            connectionState = .new
        }
    }

    private nonisolated func received(_ state: RTCPeerConnectionState, from connection: RTCPeerConnection) {
        let identity = ObjectIdentifier(connection)
        Task { @MainActor [weak self] in
            guard let self, let peer, ObjectIdentifier(peer) == identity else { return }
            connectionState = state
        }
    }
}

extension NativeCallMedia: RTCPeerConnectionDelegate {
    public nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState
    ) {
        received(newState, from: peerConnection)
    }

    public nonisolated func peerConnection(
        _: RTCPeerConnection, didChange _: RTCSignalingState
    ) {}

    public nonisolated func peerConnection(_: RTCPeerConnection, didAdd _: RTCMediaStream) {}
    public nonisolated func peerConnection(_: RTCPeerConnection, didRemove _: RTCMediaStream) {}
    public nonisolated func peerConnectionShouldNegotiate(_: RTCPeerConnection) {}

    public nonisolated func peerConnection(
        _: RTCPeerConnection, didChange _: RTCIceConnectionState
    ) {}

    public nonisolated func peerConnection(
        _: RTCPeerConnection, didChange _: RTCIceGatheringState
    ) {}

    public nonisolated func peerConnection(_: RTCPeerConnection, didGenerate _: RTCIceCandidate) {}
    public nonisolated func peerConnection(_: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {}
    public nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didOpen channel: RTCDataChannel
    ) {
        let identity = ObjectIdentifier(peerConnection)
        Task { @MainActor [weak self] in
            guard let self, let peer, ObjectIdentifier(peer) == identity,
                  let expectedControlChannel, channel.label == expectedControlChannel else {
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

extension NativeCallMedia: RTCDataChannelDelegate {
    public nonisolated func dataChannelDidChangeState(_: RTCDataChannel) {}

    public nonisolated func dataChannel(_: RTCDataChannel, didReceiveMessageWith _: RTCDataBuffer) {
        // The initial audio trial keeps the push transport open. Collection
        // state reconciliation and incoming-call handling are separate work;
        // never retain or log these private server payloads here.
    }
}
