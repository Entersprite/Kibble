import AVFoundation
import Foundation
@preconcurrency import LiveKitWebRTC
import LocalBridgeBackend

extension NativeCallMedia {
    private static func audioCryptoOptions() -> LKRTCCryptoOptions {
        LKRTCCryptoOptions(
            srtpEnableGcmCryptoSuites: true, srtpPreferGcmCryptoSuites: true,
            srtpEnableAes128Sha1_32CryptoCipher: false, srtpEnableAes128Sha1_80CryptoCipher: true,
            srtpEnableEncryptedRtpHeaderExtensions: false, sframeRequireFrameEncryption: false
        )
    }

    func preparePeer(
        serverControlChannel: String?
    ) throws -> (LKRTCPeerConnection, LKRTCMediaConstraints) {
        let factory = makeFactory()
        if !isPresentation {
            let route = NativeCallAudioRouting(factory: factory)
            audioRoute = route
            audioRouteScope = audioDevices?.install(route)
        }
        let configuration = LKRTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.cryptoOptions = Self.audioCryptoOptions()
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(
            with: configuration, constraints: constraints, delegate: self
        ) else { throw CallMediaError.negotiationFailed }
        peer = connection
        expectedControlChannel = serverControlChannel
        try installAudio(factory: factory, connection: connection)
        try Self.configureAudioCodecs(connection, factory: factory)
        try prepareVideo(factory: factory, peer: connection)
        if serverControlChannel != nil {
            // The browser also creates an ignored channel before its
            // initial offer, enabling the bundled SCTP m-line. The real
            // push channel arrives later from the server via DCEP.
            let channelConfig = LKRTCDataChannelConfiguration()
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

    private func installAudio(factory: LKRTCPeerConnectionFactory, connection: LKRTCPeerConnection) throws {
        if isPresentation, presentationAudio == nil {
            let receiving = LKRTCRtpTransceiverInit()
            receiving.direction = .recvOnly
            guard connection.addTransceiver(of: .audio, init: receiving) != nil else {
                throw CallMediaError.negotiationFailed
            }
        } else {
            let source = factory.audioSource(with: LKRTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: presentationAudio == nil ? nil : [
                    "googEchoCancellation": "false", "googAutoGainControl": "false",
                    "googNoiseSuppression": "false"
                ]
            ))
            let track = factory.audioTrack(with: source, trackId: UUID().uuidString)
            track.isEnabled = !muted
            audio = track
            guard let sender = connection.add(track, streamIds: [UUID().uuidString]) else {
                throw CallMediaError.negotiationFailed
            }
            audioSender = sender
        }
    }

    private func makeFactory() -> LKRTCPeerConnectionFactory {
        if let presentationDevice {
            LKRTCPeerConnectionFactory(
                encoderFactory: LKRTCDefaultVideoEncoderFactory(),
                decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioDevice: presentationDevice
            )
        } else {
            LKRTCPeerConnectionFactory(
                audioDeviceModuleType: .platformDefault, bypassVoiceProcessing: false,
                encoderFactory: supportsVideo ? LKRTCDefaultVideoEncoderFactory() : nil,
                decoderFactory: supportsVideo ? LKRTCDefaultVideoDecoderFactory() : nil,
                audioProcessingModule: nil
            )
        }
    }
}
