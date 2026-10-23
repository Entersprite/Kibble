import Foundation

/// Platform-owned WebRTC engine injected into the local call adapter. SDP and
/// ICE credentials are ephemeral signaling values; never store or report them.
@MainActor
public protocol CallMediaEngine: AnyObject, Sendable {
    var isConnected: Bool { get }
    var supportsStreamControl: Bool { get }
    var supportsVideo: Bool { get }
    var supportsScreenSharing: Bool { get }
    var sendsPresentationAudio: Bool { get }
    func configureScreenSharing(
        start: (@Sendable (any CallMediaEngine) async throws -> Void)?,
        stop: (@Sendable () async -> Bool)?
    )
    func showRemoteVideos(_ slots: [CallRemoteVideoSlot])
    func showRemotePresentation(_ visible: Bool)
    func renewVideoOffer() async throws -> CallAudioOffer
    func applyVideoAnswer(_ sdp: String) async throws
    func cancelVideoOffer() async
    func configureCamera(announce: (@Sendable (Bool) async throws -> Void)?)
    func reportVideoUnavailable()
    func showRemoteVideo(_ visible: Bool)
    var isMicrophoneMuted: Bool { get }
    /// Prepare bundled SCTP when a server-created control channel is expected.
    /// isConnected stays false until that channel is open as well as the peer.
    func makeAudioOffer(serverControlChannel: String?) async throws -> CallAudioOffer
    func applyAnswer(_ sdp: String) async throws
    func waitUntilConnected(timeout: Duration) async throws
    func setEventHandler(_ handler: (@Sendable (CallMediaEvent) async -> Void)?)
    func setMuted(_ muted: Bool)
    func exchangeStreamControl(
        _ request: Data, matches: @escaping @Sendable (Data) -> Bool, timeout: Duration
    ) async throws -> Data
    /// On-demand, bounded media-flow diagnostics. Fixed labels and aggregate
    /// counters only; no device names, identifiers, signaling or audio samples.
    func diagnosticReport() async -> [String]
    func close()
}

public enum CallMediaEvent: Sendable {
    case collectionsChanged
    case connected
    case disconnected
    case failed
    /// Host suspension is distinct from an audio transport failure. A paired
    /// resume gives the existing peer a fresh bounded opportunity to recover.
    case suspended, resumed
}

public extension CallMediaEngine {
    var sendsPresentationAudio: Bool {
        false
    }

    var supportsScreenSharing: Bool {
        false
    }

    func configureScreenSharing(
        start: (@Sendable (any CallMediaEngine) async throws -> Void)?,
        stop: (@Sendable () async -> Bool)?
    ) {}
    func showRemoteVideos(_ slots: [CallRemoteVideoSlot]) {
        showRemotePresentation(slots.first.map(\.isPresentation) ?? false)
        showRemoteVideo(slots.first?.isVisible ?? false)
    }

    func showRemotePresentation(_: Bool) {}

    var supportsVideo: Bool {
        false
    }

    func renewVideoOffer() async throws -> CallAudioOffer {
        throw CallMediaError.negotiationFailed
    }

    func applyVideoAnswer(_ sdp: String) async throws {
        try await applyAnswer(sdp)
    }

    func cancelVideoOffer() async {}
    func configureCamera(announce: (@Sendable (Bool) async throws -> Void)?) {}
    func reportVideoUnavailable() {}
    func showRemoteVideo(_: Bool) {}

    func diagnosticReport() async -> [String] {
        []
    }

    var supportsStreamControl: Bool {
        false
    }

    var isMicrophoneMuted: Bool {
        false
    }

    func exchangeStreamControl(
        _: Data, matches _: @escaping @Sendable (Data) -> Bool, timeout _: Duration
    ) async throws -> Data {
        throw CallMediaError.connectionFailed
    }

    func setEventHandler(_: (@Sendable (CallMediaEvent) async -> Void)?) {}

    func makeAudioOffer() async throws -> CallAudioOffer {
        try await makeAudioOffer(serverControlChannel: nil)
    }
}

/// DTLS-SRTP preference is not represented in the SDP fingerprint. Carry the
/// engine's actual preference alongside its offer instead of guessing it in
/// the provider encoder. These names contain no provider identifiers.
public enum CallSRTPProfile: String, Sendable {
    case aes128SHA180 = "AES_CM_128_HMAC_SHA1_80"
    case aeadAES128GCM = "AEAD_AES_128_GCM"
    case aeadAES256GCM = "AEAD_AES_256_GCM"
}

public struct CallAudioOffer: Sendable {
    public let sdp: String
    public let srtpProfile: CallSRTPProfile

    public init(sdp: String, srtpProfile: CallSRTPProfile) {
        self.sdp = sdp
        self.srtpProfile = srtpProfile
    }
}

public enum CallMediaError: Error, Sendable, Equatable {
    case microphoneDenied, busy, closed, negotiationFailed, connectionFailed, timedOut
    case outgoingAudioUnconfirmed, signalingTimedOut
}

/// Local receive-transceiver index; provider stream/device identifiers stay in
/// the signaling owner. The host retains independent tracks for simultaneous media.
public struct CallRemoteVideoSlot: Sendable, Equatable {
    public let index: Int
    public let isPresentation: Bool
    public let isVisible: Bool
    public let participantID: UUID?
    public let displayName: String?

    public init(
        index: Int, isPresentation: Bool, isVisible: Bool, participantID: UUID? = nil,
        displayName: String? = nil
    ) {
        self.index = index
        self.isPresentation = isPresentation
        self.isVisible = isVisible
        self.participantID = participantID
        self.displayName = displayName
    }
}
