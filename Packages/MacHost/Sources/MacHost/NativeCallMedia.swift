import AVFoundation
import Foundation
@preconcurrency import LiveKitWebRTC
import LocalBridgeBackend

/// Kibble's native media peer. Audio starts during explicit call preparation;
/// camera capture starts only through the call window's camera action.
@MainActor
public final class NativeCallMedia: NSObject, CallMediaEngine {
    private static let sslReady: Bool = {
        LKRTCSetMinDebugLogLevel(.none)
        return LKRTCInitializeSSL()
    }()

    var peer: LKRTCPeerConnection?
    let isPresentation: Bool
    var screenRoute: NativeCallScreenSharing?
    var screenScope: UUID?
    var presentationEnded: (() -> Void)?
    private var audioDevices: CallAudioDeviceController?
    private var audioRoute: NativeCallAudioRouting?
    private var audioRouteScope: UUID?
    private var audio: LKRTCAudioTrack?
    private var audioSender: LKRTCRtpSender?
    private var bootstrapChannel: LKRTCDataChannel?
    var controlChannel: LKRTCDataChannel?
    var expectedControlChannel: String?
    var generation = UUID()
    var streamChannel: LKRTCDataChannel?
    var streamReplies: [Data] = []
    var isExchangingStream = false
    var videoController: CallVideoController?
    var video: NativeCallVideo?
    var videoScope: UUID?
    var isNegotiating = false
    private var connectionState: LKRTCPeerConnectionState = .new
    private var muted = false
    var eventHandler: (@Sendable (CallMediaEvent) async -> Void)?
    private var recoveryMonitor: CallMediaRecoveryMonitor?
    private let microphoneAccess: @MainActor @Sendable () async -> Bool

    public init(
        presentation: Bool = false,
        audioDevices: CallAudioDeviceController? = nil,
        videoController: CallVideoController? = nil,
        microphoneAccess: @escaping @MainActor @Sendable () async -> Bool = {
            await AVCaptureDevice.requestAccess(for: .audio)
        }
    ) {
        isPresentation = presentation
        muted = presentation
        self.audioDevices = audioDevices
        self.videoController = videoController
        self.microphoneAccess = microphoneAccess
        super.init()
    }

    public var isConnected: Bool {
        peer?.connectionState == .connected
            && (expectedControlChannel == nil || controlChannel?.readyState == .open)
    }

    public var supportsStreamControl: Bool {
        true
    }

    public var isMicrophoneMuted: Bool {
        if let track = audioSender?.track {
            return !track.isEnabled
        }
        return audio.map { !$0.isEnabled } ?? muted
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
            let permitted = isPresentation ? true : await microphoneAccess()
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

    public func setEventHandler(_ handler: (@Sendable (CallMediaEvent) async -> Void)?) {
        eventHandler = handler
        if handler != nil, recoveryMonitor == nil {
            let scope = generation
            let monitor = CallMediaRecoveryMonitor()
            recoveryMonitor = monitor
            monitor.start { [weak self] event in await self?.recoveryEvent(event, scope: scope) }
        } else if handler == nil {
            recoveryMonitor?.stop()
            recoveryMonitor = nil
        }
    }

    private func recoveryEvent(_ event: CallMediaEvent, scope: UUID) async {
        guard generation == scope, peer != nil else { return }
        await eventHandler?(event)
    }

    public func setMuted(_ muted: Bool) {
        self.muted = muted
        audio?.isEnabled = !muted
        audioSender?.track?.isEnabled = !muted
    }

    public func close() {
        let ended = presentationEnded
        presentationEnded = nil
        ended?()
        screenRoute?.suppress()
        if let screenScope {
            videoController?.screenSharing.clear(ifCurrent: screenScope)
        }
        screenScope = nil
        screenRoute = nil
        video?.close()
        if let videoScope {
            videoController?.clear(ifCurrent: videoScope)
        }
        videoScope = nil
        video = nil
        audioRoute?.close()
        audioRoute = nil
        if let audioRouteScope {
            audioDevices?.clear(ifCurrent: audioRouteScope)
        }
        audioRouteScope = nil
        recoveryMonitor?.stop()
        recoveryMonitor = nil
        generation = UUID()
        isNegotiating = false
        audio?.isEnabled = false
        audioSender?.track?.isEnabled = false
        audio = nil
        audioSender = nil
        streamChannel?.delegate = nil
        streamChannel?.close()
        streamChannel = nil
        streamReplies.removeAll()
        isExchangingStream = false
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

    func check(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw CallMediaError.closed }
    }

    private static func audioCryptoOptions() -> LKRTCCryptoOptions {
        LKRTCCryptoOptions(
            srtpEnableGcmCryptoSuites: true, srtpPreferGcmCryptoSuites: true,
            srtpEnableAes128Sha1_32CryptoCipher: false, srtpEnableAes128Sha1_80CryptoCipher: true,
            srtpEnableEncryptedRtpHeaderExtensions: false, sframeRequireFrameEncryption: false
        )
    }

    private func preparePeer(
        serverControlChannel: String?
    ) throws -> (LKRTCPeerConnection, LKRTCMediaConstraints) {
        let factory = LKRTCPeerConnectionFactory(
            audioDeviceModuleType: .platformDefault, bypassVoiceProcessing: false,
            encoderFactory: supportsVideo ? LKRTCDefaultVideoEncoderFactory() : nil,
            decoderFactory: supportsVideo ? LKRTCDefaultVideoDecoderFactory() : nil,
            audioProcessingModule: nil
        )
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
        if isPresentation {
            let receiving = LKRTCRtpTransceiverInit()
            receiving.direction = .recvOnly
            guard connection.addTransceiver(of: .audio, init: receiving) != nil else {
                throw CallMediaError.negotiationFailed
            }
        } else {
            let track = factory.audioTrack(withTrackId: UUID().uuidString)
            track.isEnabled = !muted
            audio = track
            guard let sender = connection.add(track, streamIds: [UUID().uuidString]) else {
                throw CallMediaError.negotiationFailed
            }
            audioSender = sender
        }
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

    func setDescription(_ sdp: String, local: Bool, connection: LKRTCPeerConnection) async throws {
        let description = LKRTCSessionDescription(type: local ? .offer : .answer, sdp: sdp)
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
    }

    nonisolated func received(
        _ state: LKRTCPeerConnectionState,
        from connection: LKRTCPeerConnection
    ) {
        let identity = ObjectIdentifier(connection)
        Task { @MainActor [weak self] in
            guard let self, let peer, ObjectIdentifier(peer) == identity else { return }
            connectionState = state
            switch state {
            case .connected: await eventHandler?(.connected)
            case .disconnected: await eventHandler?(.disconnected)
            case .failed, .closed: await eventHandler?(.failed)
            default: break
            }
        }
    }
}
